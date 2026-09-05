defmodule Patchbay.Forum.Types.RewardEligibility do
  @moduledoc """
  Whether a reply can earn its author a reward.

  Every reply starts `:pending`. Moderation, by an operator or by the Patchbay
  Agent, is the only thing that moves it on.
  """

  use Ash.Type.Enum,
    values: [
      # Nobody has looked at this reply yet.
      :pending,
      # Moderation read it and it can be rewarded.
      :eligible,
      # Moderation read it and found spam.
      :ineligible_spam,
      # Moderation took it down.
      :removed
    ]
end
