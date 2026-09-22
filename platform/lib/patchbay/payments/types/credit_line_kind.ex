defmodule Patchbay.Payments.Types.CreditLineKind do
  @moduledoc """
  What moved a Patchbay Credits balance: credits bought by card, credits
  taken back because Stripe refunded or disputed the card payment, credits
  spent on a paid action, or a bounty held in credits paid out: to the author
  of the answer its asker accepted, or back to the asker after thirty days.
  """

  use Ash.Type.Enum,
    values: [:card_purchase, :card_reversal, :spend, :bounty_award, :bounty_return]
end
