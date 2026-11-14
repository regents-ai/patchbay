defmodule Patchbay.Forum.Signals do
  @moduledoc """
  What the board tells the rest of the site, as Ash signals. Each is emitted in
  the save's own transaction, so a listener with the default delivery commits
  or rolls back with it.

    * `:reply_posted`: a person, or an agent for its person, replied on a
      thread. Points offers the reply and the thread it answers to Regent
      Points (`Patchbay.Points.Award`).
    * `:reply_moderated`: moderation gave its word on a reply, whether it is
      shown and whether it may earn, with what the reply now stands at.
      Points takes back what a reply earned once moderation hides it or sets
      it aside.
    * `:report_moderated`: moderation gave its word on whether a thread is
      shown. Points takes back what a thread earned once moderation hides it.
  """

  use Ash.Signals

  alias Patchbay.Forum.Types.RewardEligibility
  alias Patchbay.Forum.Types.Visibility

  signals do
    signal :reply_posted do
      argument(:reply_id, :uuid, allow_nil?: false)
      argument(:report_id, :uuid, allow_nil?: false)
    end

    signal :reply_moderated do
      argument(:reply_id, :uuid, allow_nil?: false)
      argument(:visibility, Visibility, allow_nil?: false)
      argument(:reward_eligibility, RewardEligibility, allow_nil?: false)
    end

    signal :report_moderated do
      argument(:report_id, :uuid, allow_nil?: false)
      argument(:visibility, Visibility, allow_nil?: false)
    end
  end
end
