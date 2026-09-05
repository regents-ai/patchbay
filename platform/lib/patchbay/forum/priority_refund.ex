defmodule Patchbay.Forum.PriorityRefund do
  @moduledoc """
  Asking Base to take a bounty off the board and send it back to the asker who
  put it up.

  The escrow contract owns this rule, not Patchbay. It refuses a refund until
  thirty days after the money was recorded, and once that has passed it lets
  anybody make one, paying the asker 90% and the treasury 10%: the same split
  answering the question would have paid, so taking a bounty back is never the
  cheaper way out of it.

  Patchbay's part is only a relay for the asker's convenience, and it pays the
  gas, which is why it relays for the asker alone. Nothing here decides whether
  the money can move. Every press reaches the chain, including a press before
  the thirty days and a second press while an earlier one is in flight, and
  what the chain says is written down. A press the chain refuses costs gas and
  changes nothing, which is an accepted outcome.
  """

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @doc """
  Relays `actor`'s request to take the bounty on `report_id` back, and returns
  the report as it stands afterwards.
  """
  @spec run(String.t(), struct() | nil) :: {:ok, Report.t()} | {:error, term()}
  def run(report_id, actor) do
    with {:ok, uuid} <- uuid(report_id),
         {:ok, report} <- found_or_missing(Forum.get_report(uuid)),
         {:ok, asked} <- Forum.request_refund(report, actor: actor) do
      send_back(asked)
    end
  end

  @doc """
  Records a refund that has already happened on Base, whoever made it.

  This is how a refund Patchbay never relayed reaches the board.
  """
  @spec record(Report.t(), String.t()) :: {:ok, Report.t()} | {:error, term()}
  def record(report, tx_hash) do
    # Nothing over HTTP may write what the escrow said; this and the relay
    # below are the only places that hear it, so the write is made deliberately
    # without an actor.
    Forum.record_escrow_refund(
      report,
      %{escrow_status: :refunded, escrow_refund_tx_hash: tx_hash},
      authorize?: false
    )
  end

  defp uuid(report_id) do
    case Ecto.UUID.cast(report_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp found_or_missing({:ok, nil}), do: {:error, :not_found}
  defp found_or_missing({:ok, record}), do: {:ok, record}

  defp found_or_missing({:error, error}) do
    if missing?(error), do: {:error, :not_found}, else: {:error, error}
  end

  @doc "Whether an error means there is no such report."
  @spec missing?(term()) :: boolean()
  def missing?(%Ash.Error.Query.NotFound{}), do: true
  def missing?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &missing?/1)
  def missing?(_error), do: false

  # The money goes back to the payer the contract already recorded, so nothing
  # here says where it goes. A transaction Base accepted is not money that
  # moved, so the relay writes down the transaction and leaves the money where
  # the board believes it is until the watch sees the refund happen.
  defp send_back(asked) do
    case Escrow.refund(asked.id) do
      {:ok, tx_hash} ->
        # Nothing over HTTP may write what the escrow said, so this is written
        # deliberately without an actor.
        Forum.record_refund_relay(asked, %{escrow_refund_tx_hash: tx_hash}, authorize?: false)

      {:error, _reason} ->
        Forum.record_escrow_refund(
          asked,
          %{escrow_status: :refund_failed, escrow_refund_tx_hash: nil},
          authorize?: false
        )
    end
  end
end
