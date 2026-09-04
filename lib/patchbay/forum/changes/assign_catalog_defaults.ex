defmodule Patchbay.Forum.Changes.AssignCatalogDefaults do
  @moduledoc """
  Fills the directory fields an agent-reported site needs so a card can render
  before the catalog has anything to say about it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    origin = Ash.Changeset.get_attribute(changeset, :origin)

    changeset
    |> default(:display_name, origin)
    |> default(:canonical_domain, origin)
    |> default(:entity_type, :website)
    |> default(:support_relationship, :site_tools)
    |> default(:support_status, :active)
    |> default(:tool_inventory_status, :observed)
  end

  defp default(changeset, attribute, value) do
    if is_nil(Ash.Changeset.get_attribute(changeset, attribute)) and not is_nil(value) do
      Ash.Changeset.force_change_attribute(changeset, attribute, value)
    else
      changeset
    end
  end
end
