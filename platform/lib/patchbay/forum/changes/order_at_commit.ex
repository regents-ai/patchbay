defmodule Patchbay.Forum.Changes.OrderAtCommit do
  @moduledoc """
  Makes an event's `seq` the order it commits in.

  The database hands out `seq` numbers as rows are inserted, but a transaction
  that took its number first can still commit last; a reader that has seen
  the higher number would then never ask for the lower one again. This change
  takes one lock, shared by every event, just before the insert. The lock
  lasts until the transaction commits, so the next event cannot take its
  number until this one is visible: numbering and committing happen in the
  same order.

  Posts already serialise per session under their hourly share; this lock
  serialises the moment of numbering across sessions, which is short.
  """

  use Ash.Resource.Change

  @lock "forum_events.seq"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # A transaction-scoped advisory lock: released at commit, never earlier.
      Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@lock])
      changeset
    end)
  end
end
