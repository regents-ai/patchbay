defmodule Patchbay.Forum.RefundRelayRecord do
  @moduledoc """
  Writes down the refund transaction Patchbay sent to Base for a bounty
  (`Patchbay.Forum.PriorityRefund`), once Base has accepted it.

  Base accepting the transaction is the refund happening, so the asker is told
  so straight away, and the record follows as a job: a database too busy to
  write it then is tried again until it is written. One job a report at a time;
  a second press while one is waiting leaves the first to write its own
  transaction, and the watch (`Patchbay.Escrow.Watch`) writes the refund itself
  when it sees the money go back.
  """
  use Oban.Worker,
    queue: :escrow_records,
    max_attempts: 20,
    unique: [keys: [:report_id], period: :infinity, states: :incomplete]

  alias Patchbay.Forum

  @doc "A job that writes `tx_hash` down as the refund relayed for `report_id`."
  @spec new_record(Ash.UUID.t(), String.t()) :: Oban.Job.changeset()
  def new_record(report_id, tx_hash), do: new(%{report_id: report_id, tx_hash: tx_hash})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id, "tx_hash" => tx_hash}}) do
    # Nothing over HTTP may write what the escrow said, so this is written
    # deliberately without an actor.
    with {:ok, report} <- Forum.get_report(report_id, authorize?: false),
         {:ok, _recorded} <-
           Forum.record_refund_relay(report, %{escrow_refund_tx_hash: tx_hash}, authorize?: false) do
      :ok
    end
  end
end
