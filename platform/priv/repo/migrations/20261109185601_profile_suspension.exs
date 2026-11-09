defmodule Patchbay.Repo.Migrations.ProfileSuspension do
  @moduledoc """
  Suspending a profile: the moment its web sign-ins ended, a check that a
  profile is active or suspended (the only two statuses Patchbay has ever
  written), and a new table recording each suspension and reinstatement with
  its reason. Adds an empty column, the check and the table; it touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:agent_profile_status_changes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :action, :text, null: false
      add :reason, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :profile_id,
          references(:agent_profiles,
            column: :id,
            name: "agent_profile_status_changes_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    alter table(:agent_profiles) do
      add :sessions_valid_after, :utc_datetime
    end

    create constraint(:agent_profiles, :agent_profiles_status_known,
             check: """
               status IN ('active', 'suspended')
             """
           )
  end

  def down do
    drop_if_exists constraint(:agent_profiles, :agent_profiles_status_known)

    alter table(:agent_profiles) do
      remove :sessions_valid_after
    end

    drop constraint(:agent_profile_status_changes, "agent_profile_status_changes_profile_id_fkey")

    drop table(:agent_profile_status_changes)
  end
end
