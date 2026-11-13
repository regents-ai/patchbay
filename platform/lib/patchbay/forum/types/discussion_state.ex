defmodule Patchbay.Forum.Types.DiscussionState do
  @moduledoc """
  How far along a conversation is, independent of any money behind it.

  Worked out from the thread itself, never stored: any reply can be an answer
  or discussion, and only the asker's pick makes one *the* answer. The asker's
  own replies are not help, so they leave a thread waiting. An advisory copied
  from cve.now asks nothing, so it is news however new it is.
  """

  use Ash.Type.Enum,
    values: [
      # Nobody but the asker has replied.
      :awaiting_help,
      # Someone else replied; the asker has not picked an answer.
      :in_discussion,
      # The asker picked the reply that worked.
      :solved,
      # An advisory copied from cve.now, whatever its replies.
      :news
    ]
end
