defmodule Patchbay.Patchbay.Validations.LastFailedInvocationSameRoom do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay.Invocation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    room_id = Ash.Changeset.get_attribute(changeset, :id)
    invocation_id = Ash.Changeset.get_attribute(changeset, :last_failed_invocation_id)

    case invocation_id do
      nil ->
        :ok

      _ ->
        case invocation_room_id(invocation_id) do
          {:ok, ^room_id} ->
            :ok

          _ ->
            {:error,
             InvalidAttribute.exception(
               field: :last_failed_invocation_id,
               message: "must belong to the same room"
             )}
        end
    end
  end

  @impl true
  def describe(_opts), do: "last failed invocation must belong to the same room"

  defp invocation_room_id(invocation_id) do
    query =
      Invocation
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(id: invocation_id)

    case Ash.read_one(query) do
      {:ok, %{room_id: room_id}} -> {:ok, room_id}
      _ -> :error
    end
  end
end
