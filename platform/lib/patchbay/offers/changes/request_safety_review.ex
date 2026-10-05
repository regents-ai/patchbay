defmodule Patchbay.Offers.Changes.RequestSafetyReview do
  @moduledoc """
  Asks for a new version's safety screening in the transaction that saved
  it, so every saved version waits for one.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, version ->
      # The version's own review, made by the action that made the version.
      Patchbay.Offers.Review
      |> Ash.Changeset.for_create(:request_safety, %{version_id: version.id})
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _review} -> {:ok, version}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
