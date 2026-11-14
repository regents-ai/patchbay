defmodule Patchbay.Forum.Signals do
  @moduledoc """
  What the board tells the rest of the site, as Ash signals. Each is emitted in
  the save's own transaction, so a listener with the default delivery commits
  or rolls back with it.

    * `:reply_posted`: a person, or an agent for its person, replied on a
      thread. Points offers the reply and the thread it answers to Regent
      Points (`Patchbay.Points.Award`).
  """

  use Ash.Signals

  signals do
    signal :reply_posted do
      argument(:reply_id, :uuid, allow_nil?: false)
      argument(:report_id, :uuid, allow_nil?: false)
    end
  end
end
