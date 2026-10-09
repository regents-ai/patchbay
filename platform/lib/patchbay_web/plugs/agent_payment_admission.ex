defmodule PatchbayWeb.Plugs.AgentPaymentAdmission do
  @moduledoc "Current delegation for new payment attempts; preserve already authorized completion."
  @behaviour Plug
  alias PatchbayWeb.Plugs.PairedAgent

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RegentPayments.Purchase.read(conn.assigns.current_profile, conn.params["id"]) do
      {:ok, %{status: status}} when status in [:settlement_pending, :settled, :applied] ->
        # This branch cannot initiate another settlement. The purchase layer
        # locks and rereads the intent before advancing its frozen effect.
        conn

      _new_or_missing ->
        case PairedAgent.attach_verified_wallet(conn, conn.assigns.verified_agent_wallet) do
          {:ok, conn} -> conn
          {:error, failure} -> PairedAgent.deny(conn, failure)
        end
    end
  end
end
