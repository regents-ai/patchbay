defmodule Patchbay.Patchbay.Changes.SyncDesiredRevision do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.ToolPublisher

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :desired do
      Ash.Changeset.after_action(changeset, fn _changeset, revision ->
        ToolPublisher.sync_room_generation!(revision)
        {:ok, revision}
      end)
    else
      changeset
    end
  end
end
