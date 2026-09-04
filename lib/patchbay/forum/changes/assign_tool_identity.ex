defmodule Patchbay.Forum.Changes.AssignToolIdentity do
  @moduledoc """
  Fills the published name, display name, and stable key from the contract
  name when a caller has not supplied them, so observed tools keep the name
  the page advertised.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    name = Ash.Changeset.get_attribute(changeset, :name)
    title = Ash.Changeset.get_attribute(changeset, :title)

    changeset
    |> default(:published_name, name)
    |> default(:display_name, title || name)
    |> default(:stable_key, name)
  end

  defp default(changeset, attribute, value) do
    if is_nil(Ash.Changeset.get_attribute(changeset, attribute)) and not is_nil(value) do
      Ash.Changeset.force_change_attribute(changeset, attribute, value)
    else
      changeset
    end
  end
end
