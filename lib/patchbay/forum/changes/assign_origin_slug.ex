defmodule Patchbay.Forum.Changes.AssignOriginSlug do
  @moduledoc """
  Gives an agent-reported site a stable slug from its host when the catalog
  has not already named it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    origin = Ash.Changeset.get_attribute(changeset, :origin)
    slug = Ash.Changeset.get_attribute(changeset, :slug)

    cond do
      not is_binary(origin) ->
        changeset

      is_binary(slug) and slug != "" ->
        changeset

      site_already_registered?(origin) ->
        # Re-registering must not rewrite a catalog slug, and must not trip
        # unique_slug by proposing the host slug the same row already holds.
        changeset

      true ->
        Ash.Changeset.force_change_attribute(changeset, :slug, slug_for(origin))
    end
  end

  defp site_already_registered?(origin) do
    case Patchbay.Forum.get_site_by_origin(origin) do
      {:ok, _site} -> true
      {:error, _unknown} -> false
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
