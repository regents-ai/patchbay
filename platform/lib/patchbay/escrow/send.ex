defmodule Patchbay.Escrow.Send do
  @moduledoc """
  Patchbay's own two sends to the escrow contract for a bounty, each the
  manual update of a `Patchbay.Forum.Report` action its trigger's job runs:

    * `send: :credit` (`:send_escrow_credit`) records a filed report's money
      against its post, once the payment that paid it is in a Base block,
      since the contract refuses to record money it does not hold yet;
    * `send: :release` (`:send_escrow_release`) pays the money out to the
      author of the answer the asker accepted, at the wallet on that author's
      profile now, because that is who the asker chose to pay.

  Each asks Base first and writes after, outside any transaction, and writes
  only that the request was handed over, with its transaction: what became of
  it is `Patchbay.Escrow.Watch`'s to read. Anything that keeps the request
  from being handed over is an error, and the job tries again; a repeat is
  safe, because the contract records a post once and pays it out once, so a
  second request for the same post is refused on the chain and moves nothing.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Escrow
  alias Patchbay.Forum

  @impl true
  def update(changeset, opts, _context), do: send_request(opts[:send], changeset.data)

  # Nothing over HTTP may write what Patchbay asked of the escrow: the reads
  # and writes here are Patchbay's own, made without an actor.
  defp send_request(:credit, report) do
    with {:ok, intent} <-
           RegentPayments.get_payment_intent(report.payment_intent_id,
             load: [:receipt],
             authorize?: false
           ),
         :ok <- landed(intent.receipt.transaction_hash),
         {:ok, tx_hash} <-
           Escrow.credit(report.id, intent.receipt.payer_address, report.priority_amount_atomic) do
      Forum.record_escrow_credit(report, %{escrow_credit_tx_hash: tx_hash}, authorize?: false)
    end
  end

  # The winner's wallet is read and the payout written by Patchbay itself, as
  # the credit is.
  defp send_request(:release, report) do
    with {:ok, %{accepted_reply: %{author: author}}} <-
           Ash.load(report, [accepted_reply: [:author]], authorize?: false),
         {:ok, winner} <- wallet(author),
         {:ok, tx_hash} <- Escrow.release(report.id, winner) do
      Forum.record_escrow_release(report, %{escrow_release_tx_hash: tx_hash}, authorize?: false)
    end
  end

  defp landed(nil), do: {:error, :no_payment_transaction}

  defp landed(tx_hash) do
    case Escrow.outcome(tx_hash) do
      {:ok, :succeeded} -> :ok
      {:ok, :reverted} -> {:error, :payment_reverted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wallet(%{wallet_address: address}) when is_binary(address), do: {:ok, address}
  defp wallet(_author), do: {:error, :winner_has_no_wallet}
end
