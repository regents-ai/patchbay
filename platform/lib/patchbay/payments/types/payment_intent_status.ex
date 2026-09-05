defmodule Patchbay.Payments.Types.PaymentIntentStatus do
  use Ash.Type.Enum,
    values: [
      :prepared,
      :payment_required,
      :settlement_pending,
      :settled,
      :applied,
      :expired,
      :failed
    ]
end
