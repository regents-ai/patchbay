defmodule Patchbay.Identity.Changes.DisconnectApps do
  @moduledoc """
  Disconnects every app connected to a suspended profile
  (`Patchbay.OAuth.disconnect_apps/1`), once the suspension is saved.

  It runs after the commit, never inside it: from that moment no app can be
  handed a new token for the profile, so the apps it finds are all the apps
  there are. If it fails, the suspension still holds and running the
  suspension again finishes the disconnecting.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, profile} = result ->
        :ok = Patchbay.OAuth.disconnect_apps(profile)
        result

      _changeset, error ->
        error
    end)
  end
end
