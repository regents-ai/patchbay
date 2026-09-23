defmodule Patchbay.Repo.Migrations.PayPriorityReportsWithPatchbayCredits do
  @moduledoc """
  Records how each priority report's bounty was paid, and lets credits pay
  one out.

  Generated with `mix ash_postgres.generate_migrations`; the backfill names
  the schema it writes to, since the release migrates in the app's own.
  """

  use Ecto.Migration

  def up do
    alter table(:credit_lines) do
      add :report_id, :uuid
    end

    create unique_index(:credit_lines, [:report_id],
             name: "credit_lines_one_payout_per_bounty_index",
             where: "(kind IN ('bounty_award', 'bounty_return'))"
           )

    alter table(:forum_reports) do
      add :bounty_paid_with, :text
    end

    # Every paid priority report filed before this was paid in USDC. The
    # release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    execute(
      "UPDATE #{schema}.forum_reports SET bounty_paid_with = 'usdc' WHERE priority_amount_atomic IS NOT NULL"
    )
  end

  def down do
    alter table(:forum_reports) do
      remove :bounty_paid_with
    end

    drop_if_exists unique_index(:credit_lines, [:report_id],
                     name: "credit_lines_one_payout_per_bounty_index"
                   )

    alter table(:credit_lines) do
      remove :report_id
    end
  end
end
