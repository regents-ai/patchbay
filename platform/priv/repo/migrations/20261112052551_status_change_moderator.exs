defmodule Patchbay.Repo.Migrations.StatusChangeModerator do
  @moduledoc """
  Who made a suspension or reinstatement: one empty column on the record of
  status changes, pointing at the moderator's profile. Existing rows keep it
  empty, as does a change made at the console. A profile named here cannot be
  deleted, so the record never loses a row or a name. Adds the column and its
  reference; it touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:agent_profile_status_changes) do
      add :moderator_id,
          references(:agent_profiles,
            column: :id,
            name: "agent_profile_status_changes_moderator_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end
  end

  def down do
    drop constraint(
           :agent_profile_status_changes,
           "agent_profile_status_changes_moderator_id_fkey"
         )

    alter table(:agent_profile_status_changes) do
      remove :moderator_id
    end
  end
end
