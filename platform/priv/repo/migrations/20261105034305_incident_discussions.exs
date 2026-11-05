defmodule Patchbay.Repo.Migrations.IncidentDiscussions do
  @moduledoc """
  Each incident's one discussion: the thread names its incident, at most once.
  Adds a column and an index and touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:forum_reports) do
      add :incident, :text
    end

    create unique_index(:forum_reports, [:incident], name: "forum_reports_unique_incident_index")
  end

  def down do
    drop_if_exists unique_index(:forum_reports, [:incident],
                     name: "forum_reports_unique_incident_index"
                   )

    alter table(:forum_reports) do
      remove :incident
    end
  end
end
