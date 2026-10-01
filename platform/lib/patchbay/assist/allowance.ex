defmodule Patchbay.Assist.Allowance do
  @moduledoc """
  The free fixes a person at the page gets: one in any 24 hours for each
  connection the page is opened from, and two more in any 24 hours once
  signed in; and the two in any 24 hours an agent signed in with SIWA gets
  for its wallet. All of them only while the site as a whole has given fewer than
  `Patchbay.Config.daily_free_fixes/0` in that window. A connection is known
  by a key the page door derives from its address; nothing here knows the
  address itself.

  Every count is read from the runs themselves, so a restart forgets
  nothing. `Patchbay.Assist.request_free_run/5` reads them and opens the run
  under one lock held by every free fix, so requests that arrive together
  take the free fixes one at a time and none is given twice.
  """

  require Ash.Query

  alias Patchbay.Assist.Run
  alias Patchbay.Config

  @visitor_per_day 1
  @member_per_day 2
  @agent_per_day 2
  @day_seconds 24 * 60 * 60

  @typedoc """
  What is left: `free` fixes now, how many more `sign_in_adds` when the
  person is not signed in yet, and whether the site has `given_out` all of
  today's free fixes.
  """
  @type t :: %{free: non_neg_integer(), sign_in_adds: non_neg_integer(), given_out: boolean()}

  @doc """
  What `visitor_key`'s connection, signed in as `profile` or not, has left
  today, or why the runs could not be counted.
  """
  @spec remaining(String.t(), struct() | nil) :: {:ok, t()} | {:error, term()}
  def remaining(visitor_key, profile) do
    since = since()

    case given_out(since) do
      {:ok, true} -> {:ok, %{free: 0, sign_in_adds: 0, given_out: true}}
      {:ok, false} -> left(visitor_key, profile, since)
      {:error, _failure} = failed -> failed
    end
  end

  defp left(visitor_key, profile, since) do
    with {:ok, runs} <- visitor_runs(visitor_key, since),
         {:ok, member_left} <- member_left(profile, since) do
      visitor_left = max(@visitor_per_day - runs, 0)

      case profile do
        nil ->
          {:ok, %{free: visitor_left, sign_in_adds: @member_per_day, given_out: false}}

        _signed_in ->
          {:ok, %{free: visitor_left + member_left, sign_in_adds: 0, given_out: false}}
      end
    end
  end

  defp member_left(nil, _since), do: {:ok, 0}

  defp member_left(%{id: id}, since) do
    with {:ok, runs} <- member_runs(id, since), do: {:ok, max(@member_per_day - runs, 0)}
  end

  @doc """
  The grant the next free fix opens under: the connection's own while it has
  one, then the signed-in person's; `:none` when both are used up,
  `:given_out` when the site has no free fixes left today, and an error when
  the runs could not be counted.
  """
  @spec grant(String.t(), struct() | nil) ::
          {:ok, :visitor | :member} | :none | :given_out | {:error, term()}
  def grant(visitor_key, profile) do
    since = since()

    case given_out(since) do
      {:ok, true} -> :given_out
      {:ok, false} -> visitor_grant(visitor_key, profile, since)
      {:error, _failure} = failed -> failed
    end
  end

  defp visitor_grant(visitor_key, profile, since) do
    case visitor_runs(visitor_key, since) do
      {:ok, runs} when runs < @visitor_per_day -> {:ok, :visitor}
      {:ok, _used} -> member_grant(profile, since)
      {:error, _failure} = failed -> failed
    end
  end

  defp member_grant(%{id: id}, since) do
    case member_runs(id, since) do
      {:ok, runs} when runs < @member_per_day -> {:ok, :member}
      {:ok, _used} -> :none
      {:error, _failure} = failed -> failed
    end
  end

  defp member_grant(_not_signed_in, _since), do: :none

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

  # Same as above: the connection's own free runs, for its limit alone.
  defp visitor_runs(visitor_key, since) do
    Run
    |> Ash.Query.filter(
      grant == :visitor and visitor_key == ^visitor_key and inserted_at >= ^since
    )
    |> count()
  end

  # Same as above: Patchbay's own count, for the limit alone.
  defp member_runs(profile_id, since) do
    Run
    |> Ash.Query.filter(
      grant == :member and payer_profile_id == ^profile_id and inserted_at >= ^since
    )
    |> count()
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
