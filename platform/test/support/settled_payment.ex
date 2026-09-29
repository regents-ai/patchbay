defmodule Patchbay.SettledPayment do
  @moduledoc """
  A payment settled the way the payments library settles one, without a
  payment service: sent for settlement, its receipt written, then marked
  settled. For tests that start from money already paid.
  """

  alias RegentPayments.Steps

  @doc "Settles `intent` as paid by `payer`, and answers the settled intent and its receipt."
  @spec settle!(RegentPayments.PaymentIntent.t(), struct()) ::
          {RegentPayments.PaymentIntent.t(), RegentPayments.PaymentReceipt.t()}
  def settle!(intent, payer) do
    hash = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    {:ok, pending} = Steps.step(intent, :mark_settlement_pending, payer)

    {:ok, receipt} =
      Steps.record_receipt(
        %{
          payment_intent_id: pending.id,
          payment_identifier: pending.payment_identifier,
          payer_address: payer.wallet_address,
          network: pending.network,
          asset: pending.asset,
          amount_atomic: pending.amount_atomic,
          facilitator: "https://example.invalid/facilitator",
          transaction_hash: hash,
          payment_response: %{"success" => true, "transaction" => hash},
          settled_at: DateTime.utc_now()
        },
        payer
      )

    {:ok, settled} = Steps.step(pending, :mark_settled, payer)
    {settled, receipt}
  end
end
