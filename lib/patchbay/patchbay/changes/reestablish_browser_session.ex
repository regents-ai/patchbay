defmodule Patchbay.Patchbay.Changes.ReestablishBrowserSession do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Room

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &reestablish_if_current/1)
  end

  defp reestablish_if_current(changeset) do
    room = load_room!(changeset.data.room_id)
    desired_generation = Ash.Changeset.get_attribute(changeset, :desired_generation)
    observed_generation = Ash.Changeset.get_attribute(changeset, :observed_generation)

    if desired_generation == room.desired_tool_generation and
         observed_generation == room.desired_tool_generation do
      Ash.Changeset.force_change_attribute(changeset, :disconnected_at, nil)
    else
      changeset
    end
  end

  defp load_room!(room_id) do
    Room
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(id: room_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end
end
