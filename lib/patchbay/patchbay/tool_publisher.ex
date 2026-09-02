defmodule Patchbay.Patchbay.ToolPublisher do
  @moduledoc """
  Publishes a tool revision and its room pointer as one locked transaction.

  The underlying lifecycle actions are private to this service so callers
  cannot move a revision to `:desired` without updating the room projection,
  and without the contract it now offers reaching the public board.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, Telemetry, ToolRevision}

  require Ash.Query

  @spec publish!(ToolRevision.t(), keyword()) :: ToolRevision.t()
  def publish!(%ToolRevision{} = revision, opts \\ []) do
    started_at = System.monotonic_time()

    case Ash.transact(
           [Room, ToolRevision],
           fn -> publish_locked!(revision.id) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, revision} -> emit_publication_stop(started_at, revision)
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp publish_locked!(revision_id) do
    revision = Domain.get_tool_revision!(revision_id)
    room = Domain.get_room_for_update!(revision.room_id)

    retire_existing_desired!(room, revision)
    revision = set_revision_desired!(revision)
    _room = set_room_generation!(room, revision.generation)

    revision
  end

  defp emit_publication_stop(started_at, revision) do
    Telemetry.publication_stop(
      %{duration: System.monotonic_time() - started_at},
      %{
        room_id: revision.room_id,
        tool_revision_id: revision.id,
        tool_generation: revision.generation
      }
    )

    revision
  end

  @doc false
  @spec sync_room_generation!(ToolRevision.t(), keyword()) :: Room.t()
  def sync_room_generation!(%ToolRevision{} = revision, opts \\ []) do
    case Ash.transact(
           [Room, ToolRevision],
           fn -> sync_room_generation_locked!(revision.id) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, room} -> room
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp sync_room_generation_locked!(revision_id) do
    revision = Domain.get_tool_revision!(revision_id)
    room = Domain.get_room_for_update!(revision.room_id)

    ensure_desired!(revision)
    RoomMirror.record!(revision)
    set_room_generation!(room, revision.generation)
  end

  defp ensure_desired!(%ToolRevision{status: :desired}), do: :ok

  defp ensure_desired!(%ToolRevision{}) do
    raise Ash.Error.to_error_class(
            InvalidAttribute.exception(
              field: :status,
              message: "only a desired revision can update the room pointer"
            )
          )
  end

  defp retire_existing_desired!(room, revision) do
    ToolRevision
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(room_id == ^room.id and status == :desired and id != ^revision.id)
    |> Domain.retire_tool_revision!(bulk_options: [strategy: [:atomic, :stream]])

    :ok
  end

  defp set_revision_desired!(revision) do
    revision
    |> Ash.Changeset.for_update(:set_desired, %{}, domain: Domain)
    |> Ash.update!()
  end

  defp set_room_generation!(room, generation) do
    # The room pointer is named by no policy because no caller outside this
    # module may move it. The write runs without authorization under the lock
    # the caller already holds.
    room
    |> Ash.Changeset.for_update(:set_desired_tool_generation, %{},
      domain: Domain,
      private_arguments: %{generation: generation}
    )
    |> Ash.update!(authorize?: false)
  end
end
