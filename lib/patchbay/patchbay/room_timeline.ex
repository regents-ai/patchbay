defmodule Patchbay.Patchbay.RoomTimeline do
  @moduledoc """
  Durable, per-room ordered events for the Patchbay demo timeline.
  """

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, RoomEvent, Telemetry}

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
      {:ok, event} ->
        emit_webmcp_telemetry(event)
        event

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
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

  # The registry lifecycle only ever reaches the server as a timeline event, so
  # keying the WebMCP telemetry off the durable event keeps the page free of any
  # separate instrumentation path.
  defp emit_webmcp_telemetry(%RoomEvent{kind: kind} = event)
       when kind in [:tool_registered, :tool_unregistered, :toolchange_observed] do
    metadata = %{
      room_id: event.room_id,
      browser_session_id: event.browser_session_id,
      tool_generation: payload_value(event.payload, "generation", :generation),
      contract_sha256: payload_value(event.payload, "contract_sha256", :contract_sha256)
    }

    case kind do
      :tool_registered -> Telemetry.webmcp_registered(metadata)
      :tool_unregistered -> Telemetry.webmcp_unregistered(metadata)
      :toolchange_observed -> Telemetry.webmcp_toolchange(metadata)
    end
  end

  defp emit_webmcp_telemetry(_event), do: :ok

  defp payload_value(payload, key, atom_key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, atom_key)

  defp payload_value(_payload, _key, _atom_key), do: nil

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
