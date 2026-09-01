defmodule Patchbay.Patchbay.RoomTimeline do
  @moduledoc """
  Durable, per-room ordered events for the Patchbay demo timeline.
  """

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, RoomEvent}

  require Ash.Query

  @spec append!(Room.t() | binary(), atom(), map(), keyword()) :: RoomEvent.t()
  def append!(room_or_id, kind, payload \\ %{}, opts \\ [])

  def append!(room_or_id, kind, payload, opts) when is_map(payload) do
    room_id = if match?(%Room{}, room_or_id), do: room_or_id.id, else: room_or_id
    action_opts = Keyword.drop(opts, [:query, :browser_session_id])

    case Ash.transact(
           [Room, RoomEvent],
           fn ->
             room = lock_room!(room_id, opts)
             sequence = next_sequence!(room.id, opts)

             Domain.append_room_event!(
               %{
                 room_id: room.id,
                 browser_session_id: Keyword.get(opts, :browser_session_id),
                 sequence: sequence,
                 kind: kind,
                 payload: payload
               },
               action_opts
             )
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, event} -> event
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  def append!(_room_or_id, _kind, _payload, _opts),
    do: raise(ArgumentError, "timeline payload must be a map")

  @spec list!(Room.t() | binary(), keyword()) :: [RoomEvent.t()]
  def list!(room_or_id, opts \\ []) do
    room_id = if match?(%Room{}, room_or_id), do: room_or_id.id, else: room_or_id

    opts = Keyword.delete(opts, :browser_session_id)

    Domain.list_room_events!(
      Keyword.merge(opts, query: [filter: [room_id: room_id], sort: [sequence: :asc]])
    )
  end

  defp lock_room!(room_id, opts) do
    query_opts = Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

    execution_opts =
      Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope, :query, :browser_session_id])

    Room
    |> Ash.Query.for_read(:read, %{}, query_opts)
    |> Ash.Query.filter(id: room_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts)
  end

  defp next_sequence!(room_id, opts) do
    events =
      Domain.list_room_events!(
        Keyword.merge(Keyword.delete(opts, :browser_session_id),
          query: [filter: [room_id: room_id], sort: [sequence: :desc], limit: 1]
        )
      )

    case events do
      [%RoomEvent{sequence: sequence} | _] -> sequence + 1
      [] -> 1
    end
  end
end
