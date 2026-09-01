defmodule Patchbay.Patchbay.DemoReset do
  @moduledoc """
  Restores the one public Skill Uplift room to its checked-in generation-1
  fixture without restarting Phoenix or relying on page reload state.

  All reset writes happen while the room row is locked. This keeps revision
  lifecycle changes, proposal cleanup, and the reset event in one transaction.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
    Fixtures,
    RepairProposal,
    Room,
    RoomEvent,
    ToolPublisher,
    ToolRevision
  }

  require Ash.Query

  @spec reset!(Room.t() | String.t(), keyword()) :: Room.t()
  def reset!(room_or_slug \\ Fixtures.slug(), opts \\ []) do
    room = find_room!(room_or_slug, opts)
    action_opts = Keyword.drop(opts, [:query])

    case Ash.transact(
           [Room, BrowserSession, ToolRevision, RepairProposal, RoomEvent],
           fn ->
             room = lock_room!(room.id, opts)
             room = Domain.reset_demo!(room, action_opts)
             reset_browser_sessions!(room, opts, action_opts)
             revisions = list_revisions!(room, opts)

             Enum.each(revisions, fn revision ->
               if revision.generation != 1 and revision.status != :retired do
                 Domain.retire_tool_revision!(revision, action_opts)
               end
             end)

             seed_revision = Enum.find(revisions, &(&1.generation == 1))

             seed_revision =
               case seed_revision do
                 nil ->
                   Fixtures.revision_attributes(room.id)
                   |> Map.delete(:contract_sha256)
                   |> Map.put(:status, :candidate)
                   |> then(&Domain.create_tool_revision!(&1, action_opts))

                 %ToolRevision{status: :desired} = revision ->
                   revision

                 revision ->
                   ToolPublisher.publish!(revision, action_opts)
               end

             reject_open_proposals!(room, opts)
             append_reset_event!(room, opts)
             _ = seed_revision
             room
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, room} -> room
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp find_room!(%Room{} = room, _opts), do: room

  defp find_room!(slug, opts) when is_binary(slug) do
    case Domain.list_rooms!(Keyword.merge(opts, query: [filter: [slug: slug], limit: 1])) do
      [room | _] -> room
      [] -> raise Ash.Error.Query.NotFound.exception(resource: Room)
    end
  end

  defp lock_room!(room_id, opts) do
    query_opts = Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])
    execution_opts = Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope, :query])

    Room
    |> Ash.Query.for_read(:read, %{}, query_opts)
    |> Ash.Query.filter(id: room_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts)
  end

  defp list_revisions!(room, opts) do
    Domain.list_tool_revisions!(
      Keyword.merge(opts, query: [filter: [room_id: room.id], sort: [generation: :asc]])
    )
  end

  defp reset_browser_sessions!(room, opts, action_opts) do
    room
    |> list_browser_sessions!(opts)
    |> Enum.each(&Domain.reset_browser_session!(&1, action_opts))
  end

  defp list_browser_sessions!(room, opts) do
    query_opts = Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])
    execution_opts = Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope, :query])

    BrowserSession
    |> Ash.Query.for_read(:read, %{}, query_opts)
    |> Ash.Query.filter(room_id: room.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(execution_opts)
  end

  defp reject_open_proposals!(room, opts) do
    room
    |> list_proposals!(opts)
    |> Enum.each(fn proposal ->
      if proposal.status not in [:rejected, :published, :failed] do
        Domain.reject_repair_proposal!(proposal, Keyword.drop(opts, [:query]))
      end
    end)
  end

  defp list_proposals!(room, opts) do
    Domain.list_repair_proposals!(
      Keyword.merge(opts, query: [filter: [room_id: room.id], sort: [inserted_at: :desc]])
    )
  end

  defp append_reset_event!(room, opts) do
    sequence =
      case Domain.list_room_events!(
             Keyword.merge(opts,
               query: [filter: [room_id: room.id], sort: [sequence: :desc], limit: 1]
             )
           ) do
        [%RoomEvent{sequence: sequence} | _] -> sequence + 1
        _ -> 1
      end

    Domain.append_room_event!(
      %{
        room_id: room.id,
        sequence: sequence,
        kind: :room_reset,
        payload: %{"seed_version" => Fixtures.seed_version()}
      },
      Keyword.drop(opts, [:query])
    )
  end
end
