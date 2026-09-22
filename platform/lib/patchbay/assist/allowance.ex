defmodule Patchbay.Assist.Allowance do
  @moduledoc """
  The free fixes a person at the page gets: one in any 24 hours for each
  connection the page is opened from, and two more in any 24 hours once
  signed in, while the site as a whole has given fewer than
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
  @day_seconds 24 * 60 * 60

  @typedoc """
  What is left: `free` fixes now, how many more `sign_in_adds` when the
  person is not signed in yet, and whether the site has `given_out` all of
  today's free fixes.
  """
  @type t :: %{free: non_neg_integer(), sign_in_adds: non_neg_integer(), given_out: boolean()}

  @doc "How many free fixes a day a connection gets, and how many more a signed-in person gets."
  @spec per_day() :: %{visitor: pos_integer(), member: pos_integer()}
  def per_day, do: %{visitor: @visitor_per_day, member: @member_per_day}

  @doc "What `visitor_key`'s connection, signed in as `profile` or not, has left today."
  @spec remaining(String.t(), struct() | nil) :: t()
  def remaining(visitor_key, profile) do
    since = since()

    if given_out?(since) do
      %{free: 0, sign_in_adds: 0, given_out: true}
    else
      visitor_left = max(@visitor_per_day - visitor_runs(visitor_key, since), 0)

      case profile do
        nil ->
          %{free: visitor_left, sign_in_adds: @member_per_day, given_out: false}

        %{id: id} ->
          member_left = max(@member_per_day - member_runs(id, since), 0)
          %{free: visitor_left + member_left, sign_in_adds: 0, given_out: false}
      end
    end
  end

  @doc """
  The grant the next free fix opens under: the connection's own while it has
  one, then the signed-in person's; `:none` when both are used up, and
  `:given_out` when the site has no free fixes left today.
  """
  @spec grant(String.t(), struct() | nil) :: {:ok, :visitor | :member} | :none | :given_out
  def grant(visitor_key, profile) do
    since = since()

    cond do
      given_out?(since) ->
        :given_out

      visitor_runs(visitor_key, since) < @visitor_per_day ->
        {:ok, :visitor}

      match?(%{id: _id}, profile) and member_runs(profile.id, since) < @member_per_day ->
        {:ok, :member}

      true ->
        :none
    end
  end

  # Patchbay's own count of every free run, read for the site's limit and
  # shown to no one.
  defp given_out?(since) do
    free_runs =
      Run
      |> Ash.Query.filter(grant in [:visitor, :member] and inserted_at >= ^since)
      |> Ash.count!(authorize?: false)

    free_runs >= Config.daily_free_fixes()
  end

  # Same as above: the connection's own free runs, for its limit alone.
  defp visitor_runs(visitor_key, since) do
    Run
    |> Ash.Query.filter(
      grant == :visitor and visitor_key == ^visitor_key and inserted_at >= ^since
    )
    |> Ash.count!(authorize?: false)
  end

  # Same as above: Patchbay's own count, for the limit alone.
  defp member_runs(profile_id, since) do
    Run
    |> Ash.Query.filter(
      grant == :member and payer_profile_id == ^profile_id and inserted_at >= ^since
    )
    |> Ash.count!(authorize?: false)
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -@day_seconds, :second)
end
