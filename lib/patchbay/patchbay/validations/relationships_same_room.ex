defmodule Patchbay.Patchbay.Validations.RelationshipsSameRoom do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, opts, _context) do
    room_id = Ash.Changeset.get_attribute(changeset, :room_id)

    Enum.reduce_while(opts[:relationships] || [], :ok, fn {attribute, resource}, :ok ->
      case Ash.Changeset.get_attribute(changeset, attribute) do
        nil ->
          {:cont, :ok}

        related_id ->
          case room_id_for(resource, related_id) do
            {:ok, ^room_id} ->
              {:cont, :ok}

            _ ->
              {:halt,
               {:error,
                InvalidAttribute.exception(
                  field: attribute,
                  message: "must belong to the same room"
                )}}
          end
      end
    end)
  end

  @impl true
  def describe(opts) do
    "#{inspect(opts[:relationships])} must belong to the same room"
  end

  defp room_id_for(resource, id) do
    query =
      resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id: id)

    case Ash.read_one(query) do
      {:ok, %{room_id: room_id}} -> {:ok, room_id}
      _ -> :error
    end
  end
end
