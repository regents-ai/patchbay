defmodule Patchbay.Repo.Migrations.GoalCarriesExpectedResult do
  @moduledoc """
  A fix's goal now says both what the agent is trying to do and the result it
  expects. Each earlier run's expected result is added to its goal before the
  column goes, so no run loses what it was asked.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE assist_runs SET goal = goal || E'\\n\\nExpected: ' || expected_result
    WHERE expected_result <> ''
    """)

    alter table(:assist_runs) do
      remove :expected_result
    end
  end

  def down do
    alter table(:assist_runs) do
      add :expected_result, :text, null: false, default: ""
    end
  end
end
