defmodule Patchbay.Forum.Changes.AssignOriginSlug do
  @moduledoc """
  Gives an agent-reported site a stable slug from its host when the catalog
  has not already named it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    origin = Ash.Changeset.get_attribute(changeset, :origin)

    if is_binary(origin) and is_nil(Ash.Changeset.get_attribute(changeset, :slug)) do
      Ash.Changeset.force_change_attribute(changeset, :slug, slug_for(origin))
    else
      changeset
    end
  end

  @spec slug_for(String.t()) :: String.t()
  def slug_for(origin) do
    origin
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
