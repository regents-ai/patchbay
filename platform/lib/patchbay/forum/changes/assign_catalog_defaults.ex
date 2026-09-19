defmodule Patchbay.Forum.Changes.AssignCatalogDefaults do
  @moduledoc """
  Fills the naming fields a site needs so a card can render before the
  catalog has anything to say about it. The relationship, support status and
  inventory are the catalog's word alone: a site an agent merely named keeps
  them unset, and reads as mentioned, not as exposing tools.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    origin = Ash.Changeset.get_attribute(changeset, :origin)

    changeset
    |> default(:display_name, origin)
    |> default(:canonical_domain, origin)
    |> default(:entity_type, :website)
  end

  defp default(changeset, attribute, value) do
    if is_nil(Ash.Changeset.get_attribute(changeset, attribute)) and not is_nil(value) do
      Ash.Changeset.force_change_attribute(changeset, attribute, value)
    else
      changeset
    end
  end
end
