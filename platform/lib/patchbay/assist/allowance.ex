defmodule Patchbay.Assist.Allowance do
  @moduledoc """
  The two free fixes in any 24 hours an agent signed in with SIWA gets for
  its wallet, only while the site as a whole has given fewer than
  `Patchbay.Config.daily_free_fixes/0` in that window. The site's count takes
  in every free run, the ones the page once gave out too.

  Every count is read from the runs themselves, so a restart forgets
  nothing. `Patchbay.Assist.request_agent_free_run/2` reads them and opens
  the run under one lock held by every free fix, so requests that arrive
  together take the free fixes one at a time and none is given twice.
  """

  require Ash.Query

  alias Patchbay.Assist.Run
  alias Patchbay.Config

  @agent_per_day 2
  @day_seconds 24 * 60 * 60

  @doc """
  The grant the next free fix for the SIWA-signed `agent` opens under:
  `:none` when its wallet has used today's, `:given_out` when the site has
  no free fixes left today, and an error when the runs could not be counted.
  """
  @spec agent_grant(struct()) :: {:ok, :agent} | :none | :given_out | {:error, term()}
  def agent_grant(%{id: id}) do
    since = since()

    with {:ok, false} <- given_out(since),
         {:ok, runs} <- agent_runs(id, since) do
      if runs < @agent_per_day, do: {:ok, :agent}, else: :none
    else
      {:ok, true} -> :given_out
      {:error, _failure} = failed -> failed
    end
  end

  # Patchbay's own count of every free run, read for the site's limit and
  # shown to no one.
  defp given_out(since) do
    free_runs =
      Run
      |> Ash.Query.filter(grant in [:visitor, :member, :agent] and inserted_at >= ^since)
      |> count()

    with {:ok, runs} <- free_runs, do: {:ok, runs >= Config.daily_free_fixes()}
  end

  # Same as above: the agent's own free runs, for its limit alone.
  defp agent_runs(profile_id, since) do
    Run
    |> Ash.Query.filter(
      grant == :agent and payer_profile_id == ^profile_id and inserted_at >= ^since
    )
    |> count()
  end

  # Ash hands back a count's own errors, but a database that refuses the
  # count raises instead of answering; both come back here as an error.
  defp count(query) do
    Ash.count(query, authorize?: false)
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, failure}
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -@day_seconds, :second)
end
