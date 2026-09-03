defmodule PatchbayWeb.ForumAPI.RefundController do
  @moduledoc """
  The one endpoint behind taking your money off the board: the asker of a paid
  priority report decides no answer was worth accepting, and the money held for
  it goes back to them.

  Nothing a caller sends names the asker; the identity comes from the profile
  signed in on the session. Everything else is `Patchbay.Forum.PriorityRefund`,
  which the report page's own control comes through too.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.PriorityRefund
  alias PatchbayWeb.ForumAPI.Refusal

  def create(conn, %{"id" => id}) do
    case PriorityRefund.run(id, conn.assigns.current_profile) do
      {:ok, refunded} ->
        json(conn, %{
          # The chain decides, so this says what happened rather than that it
          # was asked for.
          withdrawn: refunded.escrow_status == :refunded,
          report_id: refunded.id,
          escrow_status: refunded.escrow_status,
          refund_tx_hash: refunded.escrow_refund_tx_hash
        })

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "There is no report with that id.", problem_code: "not_found"})
  end

  defp send_failure(conn, %Ash.Error.Forbidden{}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "Only the asker of this report can take its money back.",
      problem_code: "forbidden"
    })
  end

  defp send_failure(conn, error) do
    if PriorityRefund.missing?(error) do
      send_failure(conn, :not_found)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: Refusal.messages(error), problem_code: "invalid"})
    end
  end
end
