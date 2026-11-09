defmodule Patchbay.Repo.Migrations.ProfileSuspension do
  @moduledoc """
  Suspending a profile: the reason a person at Patchbay's console gave, and
  the moment its web sign-ins ended. Adds two empty columns and a check that a
  profile is active or suspended, the only two statuses Patchbay has ever
  written; it touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:agent_profiles) do
      add :status_reason, :text
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
      remove :status_reason
    end
  end
end
