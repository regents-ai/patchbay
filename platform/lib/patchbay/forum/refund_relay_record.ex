defmodule Patchbay.Forum.RefundRelayRecord do
  @moduledoc """
  Writes down what became of a refund transaction Patchbay sent to Base for a
  bounty (`Patchbay.Forum.PriorityRefund`), read from its receipt.

  Base accepting the transaction is only the refund being sent: the money has
  gone back when the transaction's receipt says it succeeded, and the contract
  may still refuse it (a press racing another, or one before the thirty days).
  Until it is in a block the job waits and asks again; once it is, a refund that
  succeeded is written as the refund itself and one the contract refused as
  refused. A database too busy for the write is tried again.

  One job for each transaction, so each press's own transaction is the one its
  job writes down. A transaction still not in a block an hour after it was sent
  is given up on and nothing is written: the board still believes the money is
  held, and the watch (`Patchbay.Escrow.Watch`) writes the refund itself if the
  contract ever sends it back.
  """
  use Oban.Worker,
    queue: :escrow_records,
    max_attempts: 20,
    unique: [keys: [:report_id, :tx_hash], period: :infinity, states: :incomplete]

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund

  @landing_window_s 3_600
  @asked_again_s 15

  @doc "A job that writes down what became of the refund `tx_hash` sent for `report_id`."
  @spec new_record(Ash.UUID.t(), String.t()) :: Oban.Job.changeset()
  def new_record(report_id, tx_hash), do: new(%{report_id: report_id, tx_hash: tx_hash})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id, "tx_hash" => tx_hash}} = job) do
    case Escrow.outcome(tx_hash) do
      {:ok, outcome} -> write(report_id, tx_hash, outcome)
      {:error, :not_landed} -> wait(job)
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait(%Oban.Job{inserted_at: sent_at}) do
    if DateTime.diff(DateTime.utc_now(), sent_at) < @landing_window_s,
      do: {:snooze, @asked_again_s},
      else: {:cancel, :not_landed}
  end

  # Nothing over HTTP may write what the escrow said, so the report is read
  # deliberately without an actor.
  defp write(report_id, tx_hash, outcome) do
    with {:ok, report} <- Forum.get_report(report_id, authorize?: false),
         {:ok, _written} <- written(report, tx_hash, outcome) do
      :ok
    end
  end

  defp written(report, tx_hash, :succeeded), do: PriorityRefund.record(report, tx_hash)
  defp written(report, _tx_hash, :reverted), do: PriorityRefund.refused(report)
end
