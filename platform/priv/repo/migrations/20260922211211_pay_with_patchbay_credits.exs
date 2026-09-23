defmodule Patchbay.Repo.Migrations.PayWithPatchbayCredits do
  @moduledoc """
  A credit spend points at the payment it paid for.

  Generated with `mix ash_postgres.generate_migrations`. The reference names
  no schema, like the migrations before it, so it follows the schema the
  deployment's tables live in.
  """

  use Ecto.Migration

  def up do
    alter table(:credit_lines) do
      add :payment_intent_id,
          references(:payment_intents,
            column: :id,
            name: "credit_lines_payment_intent_id_fkey",
            type: :uuid
          )

      modify :stripe_payment_intent_id, :text, null: true
    end

    create unique_index(:credit_lines, [:payment_intent_id],
             name: "credit_lines_one_spend_per_payment_index",
             where: "(kind = 'spend')"
           )

    alter table(:payment_intents) do
      add :paid_with, :text, null: false, default: "usdc"
    end
  end

  def down do
    alter table(:payment_intents) do
      remove :paid_with
    end

    drop constraint(:credit_lines, "credit_lines_payment_intent_id_fkey")

    drop_if_exists unique_index(:credit_lines, [:payment_intent_id],
                     name: "credit_lines_one_spend_per_payment_index"
                   )

    alter table(:credit_lines) do
      modify :stripe_payment_intent_id, :text, null: false
      remove :payment_intent_id
    end
  end
end
