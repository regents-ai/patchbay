defmodule Patchbay.Repo.Migrations.DisputeRestore do
  @moduledoc """
  Lets a dispute Stripe closes as won give back what its reversal took: the
  one-per-dispute rule now holds for reversals and for restores separately,
  so each dispute is taken back once and given back once.

  Generated with `mix ash_postgres.generate_migrations`. The indexes name no
  schema, like the migrations before them, so they follow the schema the
  deployment's tables live in. Rolling back refuses while a restore exists,
  since a dispute's reversal and its restore share the dispute id.
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:credit_lines, [:stripe_dispute_id],
                     name: "credit_lines_one_reversal_per_dispute_index"
                   )

    create unique_index(:credit_lines, [:stripe_dispute_id],
             name: "credit_lines_one_reversal_per_dispute_index",
             where: "(kind = 'card_reversal')"
           )

    create unique_index(:credit_lines, [:stripe_dispute_id],
             name: "credit_lines_one_restore_per_dispute_index",
             where: "(kind = 'dispute_restore')"
           )
  end

  def down do
    drop_if_exists unique_index(:credit_lines, [:stripe_dispute_id],
                     name: "credit_lines_one_restore_per_dispute_index"
                   )

    drop_if_exists unique_index(:credit_lines, [:stripe_dispute_id],
                     name: "credit_lines_one_reversal_per_dispute_index"
                   )

    create unique_index(:credit_lines, [:stripe_dispute_id],
             name: "credit_lines_one_reversal_per_dispute_index"
           )
  end
end
