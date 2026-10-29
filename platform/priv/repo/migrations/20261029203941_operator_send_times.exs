defmodule Patchbay.Repo.Migrations.OperatorSendTimes do
  @moduledoc """
  When the operator wallet last handed a report's escrow credit to Base, and
  when it last took an assist fee's forward, so Sentinel's age of each
  unconfirmed send counts from the send. Two new empty columns; no row
  changes.

  Generated with `mix ash_postgres.generate_migrations`. Nothing names a
  schema, so it follows the schema the deployment's tables live in.
  """

  use Ecto.Migration

  # Adding a column waits for every open read of its table to finish, and
  # everything behind it waits too, so it gives up after five seconds rather
  # than hold the shared database's other sites; run migrate again.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:forum_reports) do
      add :escrow_credit_sent_at, :utc_datetime_usec
    end

    alter table(:assist_runs) do
      add :fee_taken_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:assist_runs) do
      remove :fee_taken_at
    end

    alter table(:forum_reports) do
      remove :escrow_credit_sent_at
    end
  end
end
