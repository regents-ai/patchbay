defmodule Patchbay.Patchbay.DemoReset do
  @moduledoc """
  Restores a visitor's Skill Uplift room to its checked-in generation-1
  fixture without restarting Phoenix or relying on page reload state.

  All reset writes happen while the room row is locked. This keeps revision
  lifecycle changes, proposal cleanup, and the reset event in one transaction.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
    Fixtures,
    Invocation,
    InvocationRunner,
    RepairProposal,
    Room,
    RoomEvent,
    ToolPublisher,
    ToolRevision
  }

  require Ash.Query

  @spec reset!(Room.t() | String.t(), keyword()) :: Room.t()
  def reset!(room_or_slug, opts \\ []) do
    room = find_room!(room_or_slug)

    case Ash.transact(
           [Room, BrowserSession, ToolRevision, Invocation, RepairProposal, RoomEvent],
           fn -> reset_locked!(room.id) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, room} -> room
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp reset_locked!(room_id) do
    room =
      room_id
      |> Domain.get_room_for_update!()
      |> Domain.reset_demo!()

    InvocationRunner.cancel_open!(room)
    reset_browser_sessions!(room)

    revisions = list_revisions!(room)

    retire_superseded_revisions!(revisions)
    ensure_seed_revision_published!(room, revisions)
    reject_open_proposals!(room)
    append_reset_event!(room)

    room
  end

  defp retire_superseded_revisions!(revisions) do
    revisions
    |> Enum.reject(&(&1.generation == 1 or &1.status == :retired))
    |> Enum.each(&Domain.retire_tool_revision!/1)
  end

  defp find_room!(%Room{} = room), do: room

  defp find_room!(slug) when is_binary(slug) do
    Domain.get_room_by_slug!(slug)
  rescue
    Ash.Error.Invalid ->
      reraise Ash.Error.Query.NotFound.exception(resource: Room), __STACKTRACE__
  end

  defp list_revisions!(room) do
    Domain.list_tool_revisions!(query: [filter: [room_id: room.id], sort: [generation: :asc]])
  end

  defp ensure_seed_revision_published!(room, revisions) do
    case Enum.find(revisions, &(&1.generation == 1)) do
      nil ->
        room.id
        |> Fixtures.revision_attributes()
        |> Map.delete(:contract_sha256)
        |> Map.put(:status, :candidate)
        |> Domain.create_tool_revision!()
        |> ToolPublisher.publish!()

      %ToolRevision{status: :desired} = revision ->
        revision

      revision ->
        ToolPublisher.publish!(revision)
    end
  end

  defp reset_browser_sessions!(room) do
    BrowserSession
    |> Ash.Query.for_read(:for_update)
    |> Ash.Query.filter(room_id: room.id)
    |> Ash.read!()
    |> Enum.each(&Domain.reset_browser_session!/1)
  end

  defp reject_open_proposals!(room) do
    room
    |> list_proposals!()
    |> Enum.each(fn proposal ->
      if proposal.status not in [:rejected, :published, :failed] do
        Domain.reject_repair_proposal!(proposal)
      end
    end)
  end

  defp list_proposals!(room) do
    Domain.list_repair_proposals!(query: [filter: [room_id: room.id], sort: [inserted_at: :desc]])
  end

  defp append_reset_event!(room) do
    sequence =
      case Domain.list_room_events!(
             query: [filter: [room_id: room.id], sort: [sequence: :desc], limit: 1]
           ) do
        [%RoomEvent{sequence: sequence} | _] -> sequence + 1
        _ -> 1
      end

    Domain.append_room_event!(%{
      room_id: room.id,
      sequence: sequence,
      kind: :room_reset,
      payload: %{"seed_version" => Fixtures.seed_version()}
    })
  end
end
