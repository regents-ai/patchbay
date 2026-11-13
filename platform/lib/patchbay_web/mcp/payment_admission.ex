defmodule PatchbayWeb.MCP.PaymentAdmission do
  @moduledoc """
  Admits a hosted `execute_payment` call at `/mcp` exactly as
  `POST /api/agent/payment_intents/:id/execute` is admitted: the address's
  signed share is counted (`PatchbayWeb.Plugs.SignedBudget`), the exact
  request is verified as a wallet author (`PatchbayWeb.Plugs.WalletAuthor`),
  then that wallet's current pairing is required
  (`PatchbayWeb.Plugs.AgentPaymentAdmission`). Only the answer to a refusal
  differs: JSON-RPC with the request's id (`PatchbayWeb.MCP.Refusal`). A
  call with no signature at all is refused as every unsigned protected call
  at `/mcp` is (`PatchbayWeb.MCP.Refusal.unsigned/1`), and the sign-in
  service is never asked about it.
  """

  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.MCP.Refusal
  alias PatchbayWeb.Plugs.PairedAgent
  alias PatchbayWeb.Plugs.SignedBudget
  alias PatchbayWeb.Plugs.WalletAuthor

  @doc "Admits `conn`'s paying agent, or answers the refusal and halts."
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    case SignedBudget.count(conn) do
      {:ok, conn} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> verify()

      {:rate_limited, conn, seconds} ->
        Refusal.rate_limited(conn, seconds)
    end
  end

  defp verify(conn) do
    if Siwa.AgentAuthPlug.signed_request?(conn) do
      conn
      |> Siwa.AgentAuthPlug.call(
        client: WalletAuthor,
        hooks: __MODULE__,
        audience: "patchbay",
        body: :if_present
      )
      |> paired()
    else
      Refusal.unsigned(conn)
    end
  end

  # The wallet author is verified; now its current pairing, as
  # `PatchbayWeb.Plugs.AgentPaymentAdmission` requires over HTTP.
  defp paired(%{halted: true} = conn), do: conn

  defp paired(conn) do
    case PairedAgent.attach_verified_wallet(conn, conn.assigns.verified_agent_wallet) do
      {:ok, conn} -> conn
      {:error, failure} -> deny(conn, failure)
    end
  end

  # `/mcp` is not one of the wallet author's HTTP addresses, so only the
  # shared exact-request checks apply before verification.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers), do: WalletAuthor.validate_signed_request(conn, true)

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate accept(conn, data, context), to: WalletAuthor

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{source: :paired_agent} = failure) do
    {status, %{error: error}} = PairedAgent.refusal(failure)
    Refusal.refuse(conn, error, status)
  end

  # The HTTP door's own answer when wallet authors are not set up: 503.
  def deny(conn, %{reason: :not_configured}) do
    refusal =
      ApiError.body(
        "not_configured",
        "Wallet author request refused.",
        "Wallet authors are not set up on this Patchbay; sign in on a page instead."
      )

    Refusal.refuse(conn, refusal.error, 503)
  end

  def deny(conn, failure) do
    {status, %{error: error}} =
      WalletAuthor.signed_refusal(
        failure,
        "Wallet author request refused.",
        "Sign the exact request with the wallet's SIWA receipt, as /agents.md describes."
      )

    Refusal.refuse(conn, error, status)
  end
end
