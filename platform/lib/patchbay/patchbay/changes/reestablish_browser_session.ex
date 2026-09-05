defmodule Patchbay.Patchbay.Changes.ReestablishBrowserSession do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &reestablish_if_current/1)
  end

  defp reestablish_if_current(changeset) do
    room = Patchbay.Patchbay.get_room_for_update!(changeset.data.room_id)
    desired_generation = Ash.Changeset.get_attribute(changeset, :desired_generation)
    observed_generation = Ash.Changeset.get_attribute(changeset, :observed_generation)

    if desired_generation == room.desired_tool_generation and
         observed_generation == room.desired_tool_generation do
      Ash.Changeset.force_change_attribute(changeset, :disconnected_at, nil)
    else
      changeset
    end
  end
end
