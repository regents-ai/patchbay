defmodule Patchbay.Payments.Types.CreditLineKind do
  @moduledoc """
  What moved a Patchbay Credits balance: credits bought by card, or credits
  taken back because Stripe refunded or disputed the card payment.
  """

  use Ash.Type.Enum, values: [:card_purchase, :card_reversal]
end
