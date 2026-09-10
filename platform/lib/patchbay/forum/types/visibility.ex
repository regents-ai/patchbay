defmodule Patchbay.Forum.Types.Visibility do
  @moduledoc """
  Whether a record may be shown. Every public read projection applies it:
  pages, search, cards, tool reads and counts all see the same answer.

  Moderation writes this; no public action accepts it.
  """

  use Ash.Type.Enum,
    values: [
      # Readable everywhere.
      :published,
      # Held out of every public projection until a moderator decides.
      :quarantined,
      # Sensitive content removed from public rendering while the record,
      # its replies and any payment relationships stay intact.
      :redacted
    ]
end
