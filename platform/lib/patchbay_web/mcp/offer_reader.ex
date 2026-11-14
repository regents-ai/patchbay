defmodule PatchbayWeb.MCP.OfferReader do
  @moduledoc """
  Who reads a `get_thread` or `search_threads` answer at `/mcp`, for the paid
  offers that follow it (`PatchbayWeb.PaidOffers.caller_reader/1`).

  While a market is set, a call that carries a signature is counted against
  its address's signed share (`PatchbayWeb.Plugs.SignedBudget`), then checked
  as every signed door checks one: the request's own SIWA signature, read
  only, and the agent's current pairing (`PatchbayWeb.Plugs.PairedAgent`).
  When both hold, the reader is that paired agent. Anything else, a call with
  no signature, a signature that does not hold, an agent no longer paired or
  a share already spent, leaves the reader a visitor. The read is never
  refused and its answer is the one any caller gets; only the offers beside
  it may differ.
  """

  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn, only: [assign: 3]

  alias PatchbayWeb.Plugs.PairedAgent
  alias PatchbayWeb.Plugs.SignedBudget

  @doc "`conn` with the paired agent that signed it as `:offer_reader`, when there is one."
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    with true <- Patchbay.Offers.enabled?() and Siwa.AgentAuthPlug.signed_request?(conn),
         {:ok, conn} <- SignedBudget.count(conn) do
      Siwa.AgentAuthPlug.call(conn, [read_only: true] ++ PairedAgent.siwa_options(__MODULE__))
    else
      false -> conn
      {:rate_limited, conn, _seconds} -> conn
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate before_verify(conn, headers), to: PairedAgent

  # The pairing is checked as every signed door checks it; only the agent it
  # names is kept, so the call is otherwise answered as an unsigned one.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, context) do
    with {:ok, %{assigns: %{agent_actor: agent}}} <- PairedAgent.accept(conn, data, context),
         do: {:ok, assign(conn, :offer_reader, agent)}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, _failure), do: conn
end
