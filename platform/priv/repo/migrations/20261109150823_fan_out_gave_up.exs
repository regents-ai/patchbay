defmodule Patchbay.Repo.Migrations.FanOutGaveUp do
  @moduledoc """
  When a board event's fan-out ran out of attempts, apart from when it was
  delivered (`Patchbay.Forum.ForumEvent`). Adds one empty column and touches
  no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:forum_events) do
      add :fan_out_gave_up_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:forum_events) do
      remove :fan_out_gave_up_at
    end
  end
end
