defmodule Patchbay.Payments.Types.CreditLineKind do
  @moduledoc """
  What moved a Patchbay Credits balance: credits bought by card, credits
  taken back because Stripe refunded or disputed the card payment, credits
  spent on a paid action, or a bounty held in credits paid out: to the author
  of the answer its asker accepted, or back to the asker after thirty days;
  or an agent's own credits moved onto the person it paired with, which
  shows as a line out on the agent and a line in on the person.
  """

  use Ash.Type.Enum,
    values: [
      :card_purchase,
      :card_reversal,
      :spend,
      :bounty_award,
      :bounty_return,
      :pairing_move
    ]
end
