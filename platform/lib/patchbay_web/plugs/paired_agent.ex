defmodule PatchbayWeb.Plugs.PairedAgent do
  @moduledoc "Exact-request SIWA admission; owner cookies never supply agent authority."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn

  alias Patchbay.{Accounts, Identity}
  alias Patchbay.Agents.Actor
  alias PatchbayWeb.{ApiError, Plugs.WalletAuthor}

  @unsigned_hint "The request's signature headers are missing, too old or malformed. Get the newest client " <>
                   "with `curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py`, or if you use regents-cli, " <>
                   "run `uv tool upgrade regents-cli`. Then send the request with " <>
                   "`uv run siwa_agent.py request METHOD URL` or your regents command, which signs each " <>
                   "request fresh, just before sending. Each signature works once, for two minutes."

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Siwa.AgentAuthPlug.call(siwa_options(__MODULE__))
  end

  # A request with no signed header is refused here, as the sign-in service
  # itself would refuse it, so the service is never asked about it.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(%{path_info: ["api", "agent", kind | _]} = conn, headers)
      when kind in ["payment_intents", "assists"],
      do: conn |> WalletAuthor.before_verify(headers) |> require_signed(conn)

  def before_verify(conn, _headers),
    do: conn |> WalletAuthor.validate_signed_request(true) |> require_signed(conn)

  defp require_signed({:ok, _context} = admitted, conn) do
    if Siwa.AgentAuthPlug.signed_request?(conn), do: admitted, else: {:error, unsigned()}
  end

  defp require_signed(refused, _conn), do: refused

  # The sign-in service's answer to a request without signed headers: its
  # status, code and words from the shared contract, and its hint for that code.
  defp unsigned do
    {status, code, message} = Siwa.Contract.refusal(:missing_signed_headers)

    %{
      reason: :missing_signed_headers,
      source: :paired_agent,
      siwa_status: status,
      siwa_code: code,
      siwa_message: message,
      siwa_hint: @unsigned_hint
    }
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
        conn,
        %{
          "verified" => true,
          "walletAddress" => address,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => address,
            "chain_id" => 8453,
            "audience" => "patchbay"
          }
        },
        _context
      )
      when is_binary(address) do
    attach_verified_wallet(conn, address)
  end

  def accept(_conn, _data, _context), do: refused(:unsupported_principal)

  @doc "Resolve delegation after the caller has already verified this exact SIWA wallet request."
  def attach_verified_wallet(conn, address) do
    with true <- Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address),
         {:ok, pairing} <- RegentAgents.Authority.resolve(Patchbay.Repo, address),
         {:ok, %{status: :active} = beneficiary} <- local_profile(pairing.privy_user_id),
         {:ok, %{} = account} <- local_account(pairing.privy_user_id),
         {:ok, %{status: :active} = profile} <-
           Identity.upsert_from_wallet(%{wallet_address: address}, upsert_fields: []) do
      actor = Actor.new(profile, beneficiary, account, pairing)
      # A stable agent identity preserves request keys across MCP reconnects and CLI calls.
      {:ok,
       conn
       |> assign(:agent_actor, actor)
       |> assign(:current_profile, actor)
       |> assign(:forum_session_id, pairing.id)}
    else
      {:error, :not_paired} -> refused(:agent_not_paired)
      {:error, :person_not_here} -> refused(:person_not_here)
      _ -> refused(:agent_unavailable)
    end
  end

  defp local_profile(did) do
    case Identity.get_profile_by_privy_user_id(did) do
      {:ok, nil} -> {:error, :person_not_here}
      answer -> answer
    end
  end

  defp local_account(did) do
    case Accounts.by_privy(did, actor: %{role: :system}) do
      {:ok, nil} -> {:error, :person_not_here}
      answer -> answer
    end
  end

  @doc "What an agent is told, and what to do, when it is refused for `reason`."
  @spec words(:agent_not_paired | :person_not_here) :: {String.t(), String.t()}
  def words(:agent_not_paired),
    do:
      {"This agent is not paired with an account.",
       "Ask your person to sign in on this site and pair you with Pair New Agent on their Account page, then send the request again. Help: https://patchbay.help/errors/agent_not_paired"}

  def words(:person_not_here),
    do:
      {"The person this agent is paired with hasn't signed in on this site yet.",
       "Ask your person to sign in on this site once, then send the request again. Help: https://patchbay.help/errors/person_not_here"}

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, failure) do
    {status, body} = refusal(failure)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @doc """
  The status and body a refused request answers with: 403 for an agent that
  is not paired or whose person is not here, otherwise what the sign-in
  service said (`WalletAuthor.signed_refusal/3`).
  """
  @spec refusal(map()) :: {pos_integer(), %{error: map()}}
  def refusal(%{reason: reason}) when reason in [:agent_not_paired, :person_not_here] do
    {message, hint} = words(reason)
    {403, ApiError.body(to_string(reason), message, hint)}
  end

  def refusal(failure) do
    WalletAuthor.signed_refusal(
      failure,
      "A signed agent request is required.",
      "Prepare the exact request and sign it for patchbay with your existing SIWA signer. See /agents.md. Cookies confer no agent authority."
    )
  end

  @doc "The options `Siwa.AgentAuthPlug` checks a paired agent's request with, `hooks` answering."
  @spec siwa_options(module()) :: keyword()
  def siwa_options(hooks) do
    [
      client: RegentAgents.Broker,
      hooks: hooks,
      audience: "patchbay",
      body: :if_present,
      query: :signed
    ]
  end

  defp refused(reason), do: {:error, %{reason: reason, source: :paired_agent}}
end
