defmodule Patchbay.Repo.Migrations.ReversalStripeAmount do
  @moduledoc """
  Keeps, on each reversal, what Stripe's refund or dispute took from the
  payment, beside the credits the line took back, so a refund and a dispute
  of the same money are weighed against each other in whatever order they
  arrive.

  Generated with `mix ash_postgres.generate_migrations`; the backfill names
  the schema it writes to, since the release migrates in the app's own.
  """

  use Ecto.Migration

  def up do
    alter table(:credit_lines) do
      add :stripe_amount_atomic, :bigint
    end

    # Every reversal written before this took back all that its event took
    # from the payment, or all the payment had left, which is what it is
    # counted as. A plain database has no prefix and keeps the rows in
    # "public".
    schema = prefix() || "public"

    execute(
      "UPDATE #{schema}.credit_lines SET stripe_amount_atomic = -amount_atomic WHERE kind = 'card_reversal'"
    )
  end

  def down do
    alter table(:credit_lines) do
      remove :stripe_amount_atomic
    end
  end
end
