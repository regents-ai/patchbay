defmodule PatchbayWeb.Plugs.PairedAgent do
  @moduledoc "Exact-request SIWA admission; owner cookies never supply agent authority."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn

  alias Patchbay.{Accounts, Identity}
  alias Patchbay.Agents.Actor
  alias PatchbayWeb.{ApiError, Plugs.WalletAuthor}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Siwa.AgentAuthPlug.call(
      client: RegentAgents.Broker,
      hooks: __MODULE__,
      audience: "patchbay",
      body: :if_present,
      query: :signed
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(%{path_info: ["api", "agent", kind | _]} = conn, headers)
      when kind in ["payment_intents", "assists"],
      do: WalletAuthor.before_verify(conn, headers)

  def before_verify(conn, _headers), do: WalletAuthor.validate_signed_request(conn, true)

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

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: reason}) when reason in [:agent_not_paired, :person_not_here] do
    {message, hint} =
      case reason do
        :agent_not_paired ->
          {"This agent is not currently paired with an account.",
           "Ask your owner to pair this agent at https://regents.sh/account, redeem their code through POST /api/agents/v1/pair, then retry with fresh proof."}

        :person_not_here ->
          {"Your paired owner has no active Patchbay account here.",
           "Ask your owner to sign in on this Patchbay once, then retry with fresh proof."}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(ApiError.body(to_string(reason), message, hint)))
    |> halt()
  end

  def deny(conn, failure) do
    WalletAuthor.refuse_signed(
      conn,
      failure,
      "A signed agent request is required.",
      "Prepare the exact request and sign it for patchbay with your existing SIWA signer. See /agents.md. Cookies confer no agent authority."
    )
  end

  defp refused(reason), do: {:error, %{reason: reason, source: :paired_agent}}
end
