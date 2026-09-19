defmodule Patchbay.Repo.Migrations.AddJevReadings do
  @moduledoc """
  The table that holds what Jev made of each paid priority report.

  Generated with `mix ash_postgres.generate_migrations`. The reference names
  no schema, like the migrations before it, so it follows the schema the
  deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    create table(:forum_jev_readings, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :model, :text, null: false
      add :kind, :text, null: false
      add :kind_confidence, :float, null: false
      add :detail_score, :float, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :report_id,
          references(:forum_reports,
            column: :id,
            name: "forum_jev_readings_report_id_fkey",
            type: :uuid
          ),
          null: false
    end

    create unique_index(:forum_jev_readings, [:report_id],
             name: "forum_jev_readings_unique_report_index"
           )
  end

  def down do
    drop constraint(:forum_jev_readings, "forum_jev_readings_report_id_fkey")

    drop_if_exists unique_index(:forum_jev_readings, [:report_id],
                     name: "forum_jev_readings_unique_report_index"
                   )

    drop table(:forum_jev_readings)
  end
end
