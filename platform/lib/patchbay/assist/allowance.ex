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
  `{:none, seconds}` when its wallet has used today's, with the whole seconds
  until the next comes back, `:given_out` when the site has no free fixes left
  today, and an error when the runs could not be read.
  """
  @spec agent_grant(struct()) ::
          {:ok, :agent} | {:none, pos_integer()} | :given_out | {:error, term()}
  def agent_grant(%{id: id}) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -@day_seconds, :second)

    with {:ok, false} <- given_out(since),
         {:ok, asked} <- agent_asked(id, since) do
      if length(asked) < @agent_per_day,
        do: {:ok, :agent},
        else: {:none, back_in(List.last(asked), now)}
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

  # When the agent's own free runs in the window were asked for, newest first
  # and no more than its limit. Once the last of them leaves the window, a
  # free fix comes back.
  defp agent_asked(profile_id, since) do
    query =
      Run
      |> Ash.Query.filter(
        grant == :agent and payer_profile_id == ^profile_id and inserted_at >= ^since
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@agent_per_day)
      |> Ash.Query.select([:inserted_at])

    with {:ok, runs} <- read(query, &Ash.read/2), do: {:ok, Enum.map(runs, & &1.inserted_at)}
  end

  # Whole seconds, rounded up, until a run asked for `at` leaves the window.
  defp back_in(at, now) do
    left = DateTime.diff(DateTime.add(at, @day_seconds, :second), now, :millisecond)
    max(div(left + 999, 1000), 1)
  end

  defp count(query), do: read(query, &Ash.count/2)

  # Ash hands back a read's own errors, but a database that refuses the read
  # raises instead of answering; both come back here as an error.
  defp read(query, read) do
    read.(query, authorize?: false)
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, failure}
  end
end
