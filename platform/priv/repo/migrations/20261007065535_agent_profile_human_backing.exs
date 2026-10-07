defmodule Patchbay.Repo.Migrations.AgentProfileHumanBacking do
  @moduledoc """
  A wallet author keeps what its latest verified sign-in named: its registry
  page, and the World ID person behind it with how many agents they stand
  behind (Sean "139. a", 2026-10-07). Both person fields are empty when no
  verified person stands behind it. The person's number groups their agents
  and is never shown.
  """

  use Ecto.Migration

  def up do
    alter table(:agent_profiles) do
      add :registry_url, :text
      add :human_id, :text
      add :same_person_agent_count, :bigint
    end

    create constraint(:agent_profiles, :agent_profiles_human_backing_complete,
             check: """
               (human_id IS NULL AND same_person_agent_count IS NULL) OR (human_id IS NOT NULL AND same_person_agent_count IS NOT NULL AND same_person_agent_count >= 1 AND authentication_origin = 'wallet')
             """
           )

    create index(:agent_profiles, [:human_id],
             name: "agent_profiles_human_index",
             where: "human_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:agent_profiles, [:human_id], name: "agent_profiles_human_index")

    drop_if_exists constraint(:agent_profiles, :agent_profiles_human_backing_complete)

    alter table(:agent_profiles) do
      remove :same_person_agent_count
      remove :human_id
      remove :registry_url
    end
  end
end
