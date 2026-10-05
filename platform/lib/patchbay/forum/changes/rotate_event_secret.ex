defmodule Patchbay.Forum.Changes.RotateEventSecret do
  @moduledoc """
  A refresh that brings a new signing secret replaces the old one and keeps
  the old one only until `rotation_ends_at`, so a webhook in flight while the
  subscriber switches keys still verifies. A refresh with the same secret
  changes nothing about the keys.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.EventSecret

  @impl true
  def change(changeset, _opts, _context) do
    sealed = Ash.Changeset.get_argument(changeset, :secret_ciphertext)
    current = changeset.data.secret_ciphertext

    if EventSecret.open(sealed) == EventSecret.open(current) do
      changeset
    else
      Ash.Changeset.change_attributes(changeset, %{
        secret_ciphertext: sealed,
        previous_secret_ciphertext: current,
        secret_rotation_expires_at: Ash.Changeset.get_argument(changeset, :rotation_ends_at)
      })
    end
  end
end
