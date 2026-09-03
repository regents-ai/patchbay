defmodule Patchbay.Forum.PriorityRefund do
  @moduledoc """
  Sending the money behind a paid priority report back to the asker who put it
  up, when they decide no answer was worth accepting.

  Both doors on to this, the page and the board's tools, come through here, so
  the money is taken back the same way whichever one is used. The report is
  held under a row lock while it is checked and marked, so two asks arriving at
  once cannot both reach the chain, and the chain itself refuses a post whose
  money has already moved. An ask the chain does not take is written on the
  report and can be made again; it is never retried here.
  """

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @doc """
  Takes the money behind `report_id` back for `actor`, and returns the report
  as it stands afterwards.
  """
  @spec run(String.t(), struct()) :: {:ok, Report.t()} | {:error, term()}
  def run(report_id, actor) do
    # A report that does not exist is answered before the transaction opens,
    # because a rollback carries no reason back out with it.
    with {:ok, uuid} <- uuid(report_id),
         {:ok, _report} <- found_or_missing(Forum.get_report(uuid)),
         {:ok, marked} <- mark(uuid, actor) do
      send_back(marked)
    end
  end

  defp uuid(report_id) do
    case Ecto.UUID.cast(report_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The check and the mark happen under one row lock, so a second ask that
  # arrives while the first is being written waits for it and is then refused,
  # before anything reaches the chain.
  defp mark(uuid, actor) do
    case Ash.transact([Report], fn -> withdraw(uuid, actor) end) do
      {:ok, {:ok, marked}} -> {:ok, marked}
      {:error, failure} -> {:error, failure}
    end
  end

  defp withdraw(uuid, actor) do
    with {:ok, report} <- found_or_missing(Forum.lock_report(uuid, actor: actor)) do
      Forum.withdraw_priority_report(report, actor: actor)
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
  # here says where it goes.
  defp send_back(marked) do
    {status, tx_hash} =
      case Escrow.refund(marked.id) do
        {:ok, tx_hash} -> {:refunded, tx_hash}
        {:error, _reason} -> {:refund_failed, nil}
      end

    # Nothing over HTTP may write what the escrow said; this is the one place
    # that hears it, so the write is made deliberately without an actor.
    Forum.record_escrow_refund(
      marked,
      %{escrow_status: status, escrow_refund_tx_hash: tx_hash},
      authorize?: false
    )
  end
end
