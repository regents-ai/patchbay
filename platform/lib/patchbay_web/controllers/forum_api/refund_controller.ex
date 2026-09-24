defmodule PatchbayWeb.ForumAPI.RefundController do
  @moduledoc """
  The one endpoint behind asking for a bounty back: the asker of a paid
  priority report decides no answer was worth accepting, and asks Base to send
  their money back.

  Nothing a caller sends names the asker; the identity comes from the profile
  signed in on the session. Everything else is `Patchbay.Forum.PriorityRefund`,
  which the report page's own control comes through too. The contract refuses
  a refund until thirty days after the money was recorded, so a request going
  through is an answer about the request and not about the money.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.PriorityRefund
  alias PatchbayWeb.ForumAPI.Refusal

  def create(conn, %{"id" => id}) do
    case PriorityRefund.run(id, conn.assigns.current_profile) do
      {:ok, refunded} ->
        json(conn, %{
          # Base decides, and it decides later than this answer, so this says
          # only whether the request reached the chain.
          asked: is_binary(refunded.escrow_refund_tx_hash),
          report_id: refunded.id,
          escrow_status: refunded.escrow_status,
          refund_tx_hash: refunded.escrow_refund_tx_hash,
          refundable_after_days: 30
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
      error:
        "Only the asker of this report can ask Patchbay to take its money back. Anyone can call the escrow contract directly once the 30 days are up.",
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
