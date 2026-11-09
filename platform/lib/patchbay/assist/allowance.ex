defmodule Patchbay.Assist.Allowance do
  @moduledoc """
  The two free fixes in any 24 hours an agent signed in with SIWA gets for
  its wallet, only while the site as a whole has given fewer than
  `Patchbay.Config.daily_free_fixes/0` in that window. The site's count takes
  in every free run, the ones the page once gave out too.

  Every limit is read from the runs themselves, so a restart forgets
  nothing, and a refusal says how long until a free fix comes back. `Patchbay.Assist.request_agent_free_run/2` reads them and opens
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
  `{:none, seconds}` when its wallet has used today's, `{:given_out, seconds}`
  when the site has no free fixes left today, each with the whole seconds until
  one comes back, and an error when the runs could not be read.
  """
  @spec agent_grant(struct()) ::
          {:ok, :agent}
          | {:none, pos_integer()}
          | {:given_out, pos_integer()}
          | {:error, term()}
  def agent_grant(%{id: id}) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -@day_seconds, :second)

    with :ok <- limit(free_runs(since), Config.daily_free_fixes(), :given_out, now),
         :ok <- limit(agent_runs(id, since), @agent_per_day, :none, now),
         do: {:ok, :agent}
  end

  # Every free run in the window, the ones the page once gave out too, for the
  # site's limit: Patchbay's own count, shown to no one.
  defp free_runs(since),
    do: Ash.Query.filter(Run, grant in [:visitor, :member, :agent] and inserted_at >= ^since)

  # Same as above: the agent's own free runs, for its limit alone.
  defp agent_runs(profile_id, since) do
    Ash.Query.filter(
      Run,
      grant == :agent and payer_profile_id == ^profile_id and inserted_at >= ^since
    )
  end

  # `:ok` while fewer than `max` runs of `query` were asked for in the window.
  # Otherwise `{refusal, seconds}`: once the `max`th newest leaves the window,
  # one comes back. A limit of none gives nothing back by itself, so it says to
  # ask again in a day.
  defp limit(_query, 0, refusal, _now), do: {refusal, @day_seconds}

  defp limit(query, max, refusal, now) do
    query
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.offset(max - 1)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:inserted_at])
    |> read()
    |> case do
      {:ok, []} -> :ok
      {:ok, [run]} -> {refusal, back_in(run.inserted_at, now)}
      {:error, _failure} = failed -> failed
    end
  end

  # Whole seconds, rounded up, until a run asked for `at` leaves the window.
  defp back_in(at, now) do
    left = DateTime.diff(DateTime.add(at, @day_seconds, :second), now, :millisecond)
    max(div(left + 999, 1000), 1)
  end

  # Ash hands back a read's own errors, but a database that refuses the read
  # raises instead of answering; both come back here as an error.
  defp read(query) do
    Ash.read(query, authorize?: false)
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, failure}
  end
end
