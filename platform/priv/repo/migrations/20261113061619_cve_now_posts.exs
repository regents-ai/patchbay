defmodule Patchbay.Repo.Migrations.CveNowPosts do
  @moduledoc """
  Each cve.now record's one post: the post names its record, at most once, and
  when the record was last copied. Adds two columns and an index and touches
  no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:forum_reports) do
      add :cve_now_id, :text
      add :cve_now_modified_at, :utc_datetime_usec
    end

    create unique_index(:forum_reports, [:cve_now_id],
             name: "forum_reports_unique_cve_now_id_index"
           )
  end

  def down do
    drop_if_exists unique_index(:forum_reports, [:cve_now_id],
                     name: "forum_reports_unique_cve_now_id_index"
                   )

    alter table(:forum_reports) do
      remove :cve_now_modified_at
      remove :cve_now_id
    end
  end
end
