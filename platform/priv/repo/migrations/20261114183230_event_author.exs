defmodule Patchbay.Repo.Migrations.EventAuthor do
  @moduledoc """
  Each board event records who wrote what it announces
  (`ForumEvent.author_profile_id`): one new, empty column on `forum_events`.
  It adds no foreign key, as the table has none, and touches no row: events
  written before it keep no author.
  """

  use Ecto.Migration

  # It gives up after five seconds rather than hold every new post behind the
  # events table's lock; run migrate again.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:forum_events) do
      add :author_profile_id, :uuid
    end
  end

  def down do
    alter table(:forum_events) do
      remove :author_profile_id
    end
  end
end
