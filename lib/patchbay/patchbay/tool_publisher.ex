defmodule Patchbay.Patchbay.ToolPublisher do
  @moduledoc """
  Publishes a tool revision and its room pointer as one locked transaction.

  The underlying lifecycle actions are private to this service so callers
  cannot move a revision to `:desired` without updating the room projection.
  """

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, Telemetry, ToolRevision}

  @spec publish!(ToolRevision.t(), keyword()) :: ToolRevision.t()
  def publish!(%ToolRevision{} = revision, opts \\ []) do
    started_at = System.monotonic_time()

    case Ash.transact(
           [Room, ToolRevision],
           fn ->
             revision = Domain.get_tool_revision!(revision.id)
             room = Domain.get_room_for_update!(revision.room_id)
             retire_existing_desired!(room, revision)
             revision = set_revision_desired!(revision)
             _room = set_room_generation!(room, revision.generation)
             revision
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, revision} ->
        Telemetry.publication_stop(
          %{duration: System.monotonic_time() - started_at},
          %{
            room_id: revision.room_id,
            tool_revision_id: revision.id,
            tool_generation: revision.generation
          }
        )

        revision

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
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
    set_room_generation!(room, revision.generation)
  end

  defp ensure_desired!(%ToolRevision{status: :desired}), do: :ok

  defp ensure_desired!(%ToolRevision{}),
    do: raise(ArgumentError, "only a desired revision can update the room pointer")

  defp retire_existing_desired!(room, revision) do
    revisions =
      Domain.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired]])

    Enum.each(revisions, fn current ->
      if current.id != revision.id do
        Domain.retire_tool_revision!(current)
      end
    end)
  end

  defp set_revision_desired!(revision) do
    revision
    |> Ash.Changeset.for_update(:set_desired, %{}, domain: Domain)
    |> Ash.update!()
  end

  defp set_room_generation!(room, generation) do
    room
    |> Ash.Changeset.for_update(:set_desired_tool_generation, %{},
      domain: Domain,
      private_arguments: %{generation: generation}
    )
    |> Ash.update!()
  end
end
