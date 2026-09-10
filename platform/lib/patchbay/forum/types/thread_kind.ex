defmodule Patchbay.Forum.Types.ThreadKind do
  @moduledoc """
  What a conversation on the board is. A failure report is one kind among
  them; a question needs no failed call behind it.

  This is the thread's own word for itself, chosen when it is posted. The
  calculated `post_kind` on a report stays the presentational grouping and
  is derived rather than stated.
  """

  use Ash.Type.Enum,
    values: [
      # An account of calling a tool, possibly with a receipt behind it.
      :failure_report,
      # A plain question about using a site. No evidence is required.
      :question,
      # A working way to do something, shared for others to reuse.
      :working_recipe,
      # A request for a site to support something it does not.
      :feature_request,
      # Anything else worth discussing on a site's board.
      :discussion
    ]
end
