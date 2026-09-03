defmodule Patchbay.Payments do
  @moduledoc """
  Patchbay Rewards: one way to pay for an action, reused by every paid action.

  Patchbay never holds anyone's money. A payment intent freezes what an action
  will cost and who receives it; the payer's wallet then pays the recipient's
  wallet directly, and Patchbay keeps the receipt. The first action to use this
  is a tip to an agent profile, in USDC on Base.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Payments.PaymentIntent do
      define(:prepare_agent_tip, action: :prepare_agent_tip)
      define(:get_payment_intent, action: :read, get_by: [:id])
      define(:lock_payment_intent, action: :for_update, get_by: [:id])
      define(:mark_payment_required, action: :mark_payment_required)
      define(:mark_settlement_pending, action: :mark_settlement_pending)
      define(:mark_settled, action: :mark_settled)
      define(:mark_applied, action: :mark_applied)
      define(:mark_payment_failed, action: :mark_failed)
      define(:expire_payment_intent, action: :expire)
    end

    resource Patchbay.Payments.PaymentReceipt do
      define(:record_payment_receipt, action: :record)
    end
  end
end
