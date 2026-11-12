defmodule Patchbay.Repo.Migrations.AddLeftMessages do
  @moduledoc """
  Messages left for Patchbay's team: one new, empty table, `left_messages`,
  with its three indexes and its two references to `agent_profiles` (the
  person, and the agent when one left it). It changes no existing table's
  columns and touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:left_messages, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :topic, :text, null: false
      add :body, :text, null: false
      add :reply_to, :text
      add :operation_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :person_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "left_messages_person_profile_id_fkey",
            type: :uuid
          ),
          null: false

      add :agent_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "left_messages_agent_profile_id_fkey",
            type: :uuid
          )
    end

    create unique_index(:left_messages, [:agent_profile_id, :operation_id],
             name: "left_messages_agent_operation_index"
           )

    create index(:left_messages, [:person_profile_id])

    create index(:left_messages, [:inserted_at, :id])
  end

  def down do
    drop_if_exists index(:left_messages, [:inserted_at, :id])

    drop_if_exists index(:left_messages, [:person_profile_id])

    drop constraint(:left_messages, "left_messages_agent_profile_id_fkey")

    drop constraint(:left_messages, "left_messages_person_profile_id_fkey")

    drop_if_exists unique_index(:left_messages, [:agent_profile_id, :operation_id],
                     name: "left_messages_agent_operation_index"
                   )

    drop table(:left_messages)
  end
end
