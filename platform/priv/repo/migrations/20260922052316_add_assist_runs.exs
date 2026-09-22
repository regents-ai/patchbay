defmodule Patchbay.Repo.Migrations.AddAssistRuns do
  @moduledoc """
  The table that holds each paid assist.

  Generated with `mix ash_postgres.generate_migrations`. The reference names
  no schema, like the migrations before it, so it follows the schema the
  deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    create table(:assist_runs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :payer_profile_id, :uuid, null: false
      add :browser_session_id, :uuid
      add :goal, :text, null: false
      add :site_url, :text, null: false
      add :expected_result, :text, null: false
      add :sign_in, :text, null: false
      add :believed_calls, {:array, :map}, null: false, default: []
      add :status, :text, null: false, default: "paid"
      add :outcome, :text
      add :steps, {:array, :map}, null: false, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :payment_intent_id,
          references(:payment_intents,
            column: :id,
            name: "assist_runs_payment_intent_id_fkey",
            type: :uuid
          ),
          null: false
    end

    create unique_index(:assist_runs, [:payment_intent_id],
             name: "assist_runs_one_run_per_payment_index"
           )
  end

  def down do
    drop constraint(:assist_runs, "assist_runs_payment_intent_id_fkey")

    drop_if_exists unique_index(:assist_runs, [:payment_intent_id],
                     name: "assist_runs_one_run_per_payment_index"
                   )

    drop table(:assist_runs)
  end
end
