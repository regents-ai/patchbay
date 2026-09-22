defmodule Patchbay.Assist.Allowance do
  @moduledoc """
  The free fixes a person at the page gets: one in any 24 hours for each
  connection the page is opened from, and two more in any 24 hours once
  signed in. A connection is known by a key the page door derives from its
  address; nothing here knows the address itself.

  Both counts are read from the runs themselves, so a restart forgets
  nothing. `Patchbay.Assist.request_free_run/5` reads them and opens the run
  under one lock on the connection's key, so requests that arrive together
  from one connection take its free fix one at a time; a signed-in person's
  are held to one open run at a time by the database.
  """

  require Ash.Query

  alias Patchbay.Assist.Run

  @visitor_per_day 1
  @member_per_day 2
  @day_seconds 24 * 60 * 60

  @typedoc """
  What is left: `free` fixes now, and how many more `sign_in_adds` when the
  person is not signed in yet.
  """
  @type t :: %{free: non_neg_integer(), sign_in_adds: non_neg_integer()}

  @doc "How many free fixes a day a connection gets, and how many more a signed-in person gets."
  @spec per_day() :: %{visitor: pos_integer(), member: pos_integer()}
  def per_day, do: %{visitor: @visitor_per_day, member: @member_per_day}

  @doc "What `visitor_key`'s connection, signed in as `profile` or not, has left today."
  @spec remaining(String.t(), struct() | nil) :: t()
  def remaining(visitor_key, profile) do
    since = since()
    visitor_left = max(@visitor_per_day - visitor_runs(visitor_key, since), 0)

    case profile do
      nil ->
        %{free: visitor_left, sign_in_adds: @member_per_day}

      %{id: id} ->
        %{free: visitor_left + max(@member_per_day - member_runs(id, since), 0), sign_in_adds: 0}
    end
  end

  @doc """
  The grant the next free fix opens under: the connection's own while it has
  one, then the signed-in person's, or nothing when both are used up.
  """
  @spec grant(String.t(), struct() | nil) :: {:ok, :visitor | :member} | :none
  def grant(visitor_key, profile) do
    since = since()

    cond do
      visitor_runs(visitor_key, since) < @visitor_per_day ->
        {:ok, :visitor}

      match?(%{id: _id}, profile) and member_runs(profile.id, since) < @member_per_day ->
        {:ok, :member}

      true ->
        :none
    end
  end

  # Patchbay's own count of free runs, read for a limit and shown to no one.
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
