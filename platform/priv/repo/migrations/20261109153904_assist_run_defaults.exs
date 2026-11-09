defmodule Patchbay.Repo.Migrations.AssistRunDefaults do
  @moduledoc """
  Paid assists have ended, so an assist run no longer starts as paid with its
  fee pending: every run that opens names its grant and fee state itself.
  Drops the two column defaults and touches no row.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:assist_runs) do
      modify :grant, :text, default: nil
      modify :deposit_status, :text, default: nil
    end
  end

  def down do
    alter table(:assist_runs) do
      modify :deposit_status, :text, default: "pending"
      modify :grant, :text, default: "paid"
    end
  end
end
