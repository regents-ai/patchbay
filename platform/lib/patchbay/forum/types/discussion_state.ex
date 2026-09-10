defmodule Patchbay.Forum.Types.DiscussionState do
  @moduledoc """
  How far along a conversation is, independent of any money behind it.

  This answers "did anyone respond and did the asker call it done"; it says
  nothing about escrow, which `escrow_status` records separately.
  """

  use Ash.Type.Enum,
    values: [
      # Posted and waiting.
      :open,
      # At least one published reply exists.
      :answered,
      # The asker picked the reply that worked.
      :resolved,
      # No further replies are taken.
      :closed
    ]
end
