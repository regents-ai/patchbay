defmodule Patchbay.Patchbay.ToolPublisher do
  @moduledoc """
  Publishes a tool revision and its room pointer as one locked transaction.

  The underlying lifecycle actions are private to this service so callers
  cannot move a revision to `:desired` without updating the room projection.
  """

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, ToolRevision}

  require Ash.Query

  @spec publish!(ToolRevision.t(), keyword()) :: ToolRevision.t()
  def publish!(%ToolRevision{} = revision, opts \\ []) do
    case Ash.transact(
           [Room, ToolRevision],
           fn ->
             revision = load_revision!(revision.id, opts)
             room = lock_room!(revision.room_id, opts)
             retire_existing_desired!(room, revision, opts)
             revision = set_revision_desired!(revision, opts)
             _room = set_room_generation!(room, revision.generation, opts)
             revision
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, revision} -> revision
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  @doc false
  @spec sync_room_generation!(ToolRevision.t(), keyword()) :: Room.t()
  def sync_room_generation!(%ToolRevision{} = revision, opts \\ []) do
    case Ash.transact(
           [Room, ToolRevision],
           fn ->
             revision = load_revision!(revision.id, opts)
             room = lock_room!(revision.room_id, opts)

             if revision.status != :desired do
               raise ArgumentError, "only a desired revision can update the room pointer"
             end

             set_room_generation!(room, revision.generation, opts)
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, room} -> room
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp load_revision!(revision_id, opts) do
    Domain.get_tool_revision!(revision_id, Keyword.drop(opts, [:query]))
  end

  defp retire_existing_desired!(room, revision, opts) do
    revisions =
      Domain.list_tool_revisions!(
        Keyword.merge(Keyword.drop(opts, [:query]),
          query: [filter: [room_id: room.id, status: :desired]]
        )
      )

    Enum.each(revisions, fn current ->
      if current.id != revision.id do
        Domain.retire_tool_revision!(current, action_opts(opts))
      end
    end)
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

  defp set_revision_desired!(revision, opts) do
    revision
    |> Ash.Changeset.for_update(
      :set_desired,
      %{},
      Keyword.put(
        Keyword.take(opts, [:actor, :tenant, :authorize?, :scope]),
        :domain,
        Patchbay.Patchbay
      )
    )
    |> Ash.update!(Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope]))
  end

  defp action_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

  defp set_room_generation!(room, generation, opts) do
    room
    |> Ash.Changeset.for_update(
      :set_desired_tool_generation,
      %{generation: generation},
      Keyword.put(
        Keyword.take(opts, [:actor, :tenant, :authorize?, :scope]),
        :domain,
        Patchbay.Patchbay
      )
      |> Keyword.put(:private_arguments, %{generation: generation})
    )
    |> Ash.update!(Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope]))
  end
end
