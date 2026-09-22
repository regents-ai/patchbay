defmodule Patchbay.Payments.Types.CreditLineKind do
  @moduledoc """
  What moved a Patchbay Credits balance: credits bought by card, credits
  taken back because Stripe refunded or disputed the card payment, or credits
  spent on a paid action.
  """

  use Ash.Type.Enum, values: [:card_purchase, :card_reversal, :spend]
end
