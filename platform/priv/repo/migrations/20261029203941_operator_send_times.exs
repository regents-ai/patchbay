defmodule Patchbay.Repo.Migrations.OperatorSendTimes do
  @moduledoc """
  When the operator wallet last handed a report's escrow credit to Base, and
  when it last took an assist fee's forward, so Sentinel's age of each
  unconfirmed send counts from the send. Two new columns.

  The columns were generated with `mix ash_postgres.generate_migrations`; the
  rest is written by hand. Its `up` also gives a
  send time to every send already waiting as it runs (Sean, 83 b). A report
  whose credit Base has not yet confirmed takes its filing time: reports keep
  no update time, and the credit is first handed over as soon as the report is filed.
  A fee being forwarded takes its run's last update time, which is the taking
  unless something wrote the run since. The count each gets is printed in the
  release step. `down` drops the columns and the times with them.
  """

  use Ecto.Migration

  # The tables are named in the schema the migrator is putting them in
  # (`prefix()`; `public` when it names none), which in production is not on the
  # connection's search path. It is one of the two names runtime.exs allows, so
  # the statements for each are written here.
  @credit_sent_at """
  UPDATE SCHEMA.forum_reports
  SET escrow_credit_sent_at = inserted_at
  WHERE escrow_status = 'credit_submitted'
  """
  @fee_taken_at """
  UPDATE SCHEMA.assist_runs
  SET fee_taken_at = updated_at
  WHERE deposit_status = 'forwarding'
  """
  @send_times_public Enum.map(
                       [@credit_sent_at, @fee_taken_at],
                       &String.replace(&1, "SCHEMA.", "public.")
                     )
  @send_times_patchbay_app Enum.map(
                             [@credit_sent_at, @fee_taken_at],
                             &String.replace(&1, "SCHEMA.", "patchbay_app.")
                           )

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

    # Both tables are locked from here to the end, so the counts printed are
    # the counts that commit.
    flush()

    [credit_sent_at, fee_taken_at] = send_times(prefix() || "public")
    %{num_rows: credits} = repo().query!(credit_sent_at)
    %{num_rows: fees} = repo().query!(fee_taken_at)
    IO.puts("forum_reports: #{credits} waiting credit(s) given a send time")
    IO.puts("assist_runs: #{fees} fee forward(s) given a taken time")
  end

  def down do
    alter table(:assist_runs) do
      remove :fee_taken_at
    end

    alter table(:forum_reports) do
      remove :escrow_credit_sent_at
    end
  end

  defp send_times("public"), do: @send_times_public
  defp send_times("patchbay_app"), do: @send_times_patchbay_app
end
