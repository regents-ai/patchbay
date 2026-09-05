defmodule Patchbay.Patchbay.Validations.InvocationEpochIsCurrent do
  @moduledoc """
  A call belongs to one run of the room.

  Resetting the demo starts a new run, so a call begun before the reset, or a
  request that still believes in the run it was written against, is turned away
  rather than allowed to write into the run that replaced it.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain

  @impl true
  def validate(changeset, _opts, _context) do
    room_id = Ash.Changeset.get_attribute(changeset, :room_id)
    room = Domain.get_room_by_id!(room_id, query: [select: [:id, :invocation_epoch]])

    if Ash.Changeset.get_attribute(changeset, :invocation_epoch) == room.invocation_epoch do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :invocation_epoch,
         message: "invocation belongs to an earlier room lifecycle"
       )}
    end
  end

  @impl true
  def describe(_opts), do: "invocation must belong to the room's current lifecycle"
end
