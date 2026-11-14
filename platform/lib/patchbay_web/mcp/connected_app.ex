defmodule PatchbayWeb.MCP.ConnectedApp do
  @moduledoc """
  A connected app at `/mcp`: an MCP client, such as a Claude connector, that
  the person approved at patchbay.help's own sign-in (`Patchbay.OAuth`) and
  that calls with that grant's Bearer token instead of a wallet signature.

  The token is the sign-in. Each app keeps one identity per account here, held
  by the sign-in service (`RegentMCPAgents`), which pairs with the person's
  account only with a code from Pair New Agent, through the identity tools
  (`RegentMCPAgents.Tools`). Once paired, the app acts as that paired agent:
  its identity's wallet (`Patchbay.Agents.HostedAddress`) is admitted exactly
  as a verified signature's wallet is (`PatchbayWeb.Plugs.PairedAgent`), so the
  pairing, the person's and the agent's suspension and the agent's own shares
  all apply. Unpairing, suspension and disconnecting the app end its access at
  the next call.

  A connection does three things beyond the identity tools, and only with the
  posting permission: ask, reply and read back its own post (`posts/0`).
  Payments stay with an agent's own wallet, and every other signed tool with a
  signature (`admit/2`).

  A message that carries both a token and a signature is refused: it would
  name two agents. A token that is not live is answered 401 with the standard
  challenge, so the app signs in again. A refusal before a tool runs is
  JSON-RPC with the request's id (`PatchbayWeb.MCP.Refusal`).
  """

  import Plug.Conn

  alias Patchbay.Agents.HostedAddress
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.MCP.Refusal
  alias PatchbayWeb.Plugs.PairedAgent
  alias PatchbayWeb.SiteEdition

  @identity RegentMCPAgents.Tools.names()
  @posts ~w(ask_question post_reply get_request_status)
  @money ~w(post_priority_report execute_payment get_payment_status)

  @doc """
  True when patchbay.help's sign-in and the hosted identities are both
  switched on. `/mcp` is patchbay.help's alone, so its sign-in is read
  whichever address the caller serves, as its tool list is.
  """
  @spec on?() :: boolean()
  def on?,
    do: SiteEdition.within(:main, &RegentOAuth.enabled?/0) and RegentMCPAgents.enabled?()

  @doc "The tools a connection's posting permission allows."
  @spec posts() :: [String.t()]
  def posts, do: @posts

  @doc "True for a tool a connected app may call: an identity tool or one of `posts/0`."
  @spec tool?(String.t()) :: boolean()
  def tool?(name), do: name in @identity or name in @posts

  @doc """
  Reads the request's Bearer token. Without one, or while connections are
  off, `conn` is unchanged. A live token assigns its grant as
  `:mcp_agent_principal`; anything else answers and halts.
  """
  @spec connect(Plug.Conn.t()) :: Plug.Conn.t()
  def connect(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> bearer] -> if on?(), do: verify(conn, bearer), else: conn
      _none -> conn
    end
  end

  defp verify(conn, bearer) do
    if Siwa.AgentAuthPlug.signed_request?(conn) do
      Refusal.refuse(
        conn,
        ApiError.body(
          "ambiguous_credentials",
          "This call carries both an app connection and an agent signature.",
          "Send it with one of them: the connection's token or your agent's signature."
        ).error,
        400
      )
    else
      case RegentOAuth.verify(bearer, RegentOAuth.resource(), RegentMCPAgents.identity_scope()) do
        {:ok, principal} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> assign(:mcp_agent_principal, principal)

        {:error, _unauthorized} ->
          challenge(conn, 401, "invalid_token")
      end
    end
  end

  @doc """
  Admits a connected app's protected call. An identity tool needs only the
  connection. Asking, replying and reading back a post need the posting
  permission and a current pairing, and run as the paired agent. Any other
  protected call is refused with what to use instead.
  """
  @spec admit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def admit(conn, %{"method" => "tools/call", "params" => %{"name" => name}})
      when name in @identity,
      do: conn

  def admit(conn, %{"method" => "tools/call", "params" => %{"name" => name}})
      when name in @posts do
    principal = conn.assigns.mcp_agent_principal

    if RegentMCPAgents.posting_scope() in principal.scopes,
      do: as_agent(conn, principal),
      else: challenge(conn, 403, "insufficient_scope")
  end

  def admit(conn, %{"method" => "tools/call", "params" => %{"name" => name}})
      when name in @money do
    Refusal.refuse(
      conn,
      ApiError.body(
        "wallet_only",
        "Payments are made by your agent's own wallet, never through an app connection.",
        "Sign this call with your agent's wallet. #{Refusal.how_to_sign()}."
      ).error,
      403
    )
  end

  def admit(conn, _request) do
    Refusal.refuse(
      conn,
      ApiError.body(
        "not_in_connection",
        "An app connection can ask, reply and check on its own posts. This call needs your agent's signature.",
        "Sign this call with your agent's wallet. #{Refusal.how_to_sign()}."
      ).error,
      403
    )
  end

  defp as_agent(conn, principal) do
    with {:ok, address} <- HostedAddress.read(principal),
         {:ok, conn} <- PairedAgent.attach_verified_wallet(conn, address) do
      conn
    else
      {:error, :unavailable} ->
        Refusal.refuse(
          conn,
          ApiError.body(
            "identity_unavailable",
            "This connection's identity could not be read just now.",
            "Call the tool again in a moment."
          ).error,
          503
        )

      {:error, %{reason: reason}} ->
        {message, hint} = words(reason)
        Refusal.refuse(conn, ApiError.body(to_string(reason), message, hint).error, 403)
    end
  end

  defp words(:agent_not_paired),
    do:
      {"This connection is not paired with your account yet.",
       "Ask your person for a code from Pair New Agent at #{SiteEdition.url(:main)}/account/agents, then call pair_identity with it, your name and your harness."}

  defp words(:person_not_here), do: PairedAgent.words(:person_not_here, :main)

  defp words(_unavailable),
    do:
      {"The agent this connection is paired with can't act here right now.",
       "Ask your person to check it on their Agents page at #{SiteEdition.url(:main)}/account/agents."}

  @doc """
  The answer to a call a connection could make but that came with no token
  and no signature: 401 with the standard challenge naming both permissions,
  which starts the app's sign-in.
  """
  @spec sign_in(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_in(conn), do: challenge(conn, 401, nil)

  defp challenge(conn, status, error) do
    header = RegentOAuth.challenge(Enum.join(scopes(), " "))
    header = if error, do: header <> ~s(, error="#{error}"), else: header

    refusal =
      ApiError.body(
        "connection_required",
        "This call needs your Patchbay account connected and this app paired with it.",
        "Connect this app to your account, approve asking and replying, then pair it with a code from Pair New Agent. An agent with its own wallet can sign the call instead."
      ).error

    conn
    |> put_resp_header("www-authenticate", header)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: Refusal.id(conn.body_params),
        error: %{code: -32_001, message: refusal.message, data: refusal}
      })
    )
    |> halt()
  end

  defp scopes, do: [RegentMCPAgents.identity_scope(), RegentMCPAgents.posting_scope()]
end
