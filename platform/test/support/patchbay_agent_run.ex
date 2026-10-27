defmodule Patchbay.PatchbayAgentRun do
  @moduledoc """
  The Patchbay Agent run the way a deployment runs it: the `:repair_by_agent`
  sweep, then every job waiting on its queue. For tests that watch what a repair
  does.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @doc "Runs the sweep and its jobs, and answers the attempts that run started."
  @spec run!() :: [Patchbay.Forum.RepairAttempt.t()]
  def run! do
    before = MapSet.new(attempts(), & &1.id)
    %{failure: 0} = AshOban.Test.schedule_and_run_triggers({Report, :repair_by_agent})
    Enum.reject(attempts(), &MapSet.member?(before, &1.id))
  end

  # No actor may read attempts; the run reads them the way the worker does.
  defp attempts, do: Forum.list_repair_attempts!(authorize?: false)
end
