defmodule Patchbay.Repo.Migrations.PairAgentsWithPeople do
  @moduledoc """
  Pairs an agent with the person it works for, by a one-time code.

  Generated with `mix ash_postgres.generate_migrations`. The references name
  no schema, like the migrations before it, so they follow the schema the
  deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    alter table(:agent_profiles) do
      add :paired_person_id,
          references(:agent_profiles,
            column: :id,
            name: "agent_profiles_paired_person_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )
    end

    create constraint(:agent_profiles, :agent_profiles_only_wallet_authors_pair,
             check: """
               paired_person_id IS NULL OR authentication_origin = 'wallet'
             """
           )

    create index(:agent_profiles, [:paired_person_id])

    create table(:pairing_codes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :code_sha256, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :person_id,
          references(:agent_profiles,
            column: :id,
            name: "pairing_codes_person_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:pairing_codes, [:person_id],
             name: "pairing_codes_one_code_per_person_index"
           )

    create unique_index(:pairing_codes, [:code_sha256], name: "pairing_codes_unique_code_index")
  end

  def down do
    drop constraint(:pairing_codes, "pairing_codes_person_id_fkey")

    drop_if_exists unique_index(:pairing_codes, [:code_sha256],
                     name: "pairing_codes_unique_code_index"
                   )

    drop_if_exists unique_index(:pairing_codes, [:person_id],
                     name: "pairing_codes_one_code_per_person_index"
                   )

    drop table(:pairing_codes)

    drop_if_exists index(:agent_profiles, [:paired_person_id])

    drop_if_exists constraint(:agent_profiles, :agent_profiles_only_wallet_authors_pair)

    drop constraint(:agent_profiles, "agent_profiles_paired_person_id_fkey")

    alter table(:agent_profiles) do
      remove :paired_person_id
    end
  end
end
