defmodule Patchbay.Patchbay.RoomCapacity do
  @moduledoc """
  Keeps the number of demo rooms bounded.

  Anything that can reach the site can ask for a room: crawlers, link
  previewers, uptime checks. Every request for a new room therefore first
  sweeps away rooms nobody used, and refuses once the deployment is full
  rather than growing without limit.
  """

  alias Patchbay.Config
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.Room

  # Any fixed key works; it only has to be the same for every room creation.
  @capacity_lock 4711

  @doc """
  Sweeps unused rooms, then creates a room under `slug`.

  Returns `{:error, :at_capacity}` when the deployment is full even after the
  sweep, which the caller turns into a "come back later" page.
  """
  @spec create_room(String.t()) :: {:ok, Room.t()} | {:error, :at_capacity}
  def create_room(slug) when is_binary(slug) do
    case Ash.transact(Room, fn -> sweep_then_create(slug) end) do
      {:ok, :at_capacity} -> {:error, :at_capacity}
      {:ok, %Room{} = room} -> {:ok, room}
    end
  end

  # The sweep, the count and the insert run under one advisory lock so a burst
  # of first visits cannot all read the same count and all proceed; without it
  # the ceiling is only advisory. A deployment that is still full after the
  # sweep keeps the sweep: it freed what it could, and refusing is an answer
  # rather than a failed write.
  defp sweep_then_create(slug) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@capacity_lock])
    reap_unused_rooms()

    if room_count() >= Config.max_rooms(),
      do: :at_capacity,
      else: Domain.create_seeded_room!(slug)
  end

  @doc """
  Deletes rooms that have sat untouched past the idle window without ever
  recording an invocation. Everything that belongs to such a room goes with it.
  """
  @spec reap_unused_rooms() :: :ok
  def reap_unused_rooms do
    cutoff = DateTime.add(DateTime.utc_now(), -Config.room_idle_hours(), :hour)

    Room
    |> Ash.Query.for_read(:idle_and_unused, %{untouched_since: cutoff})
    |> Domain.discard_room!(bulk_options: [strategy: [:atomic, :stream]])

    :ok
  end

  defp room_count do
    Room
    |> Ash.Query.for_read(:read)
    |> Ash.count!()
  end
end
