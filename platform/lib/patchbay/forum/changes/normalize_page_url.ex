defmodule Patchbay.Forum.Changes.NormalizePageUrl do
  @moduledoc """
  Keeps the page a post names as `Origin.address/1` writes it, `https://`
  plus the host and path, and refuses a page that is not on the post's site.
  The site is the domain the board groups by; the page is where on it the
  poster used the site's tools.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :page_url) do
      nil -> changeset
      page_url -> normalize(changeset, page_url)
    end
  end

  defp normalize(changeset, page_url) do
    # Reads the post's site to compare; it grants nothing.
    with {:ok, address} <- Origin.address(page_url),
         {:ok, domain} <- Origin.normalize(address),
         {:ok, %{origin: ^domain}} <-
           Forum.get_site(Ash.Changeset.get_attribute(changeset, :site_id), authorize?: false) do
      Ash.Changeset.force_change_attribute(changeset, :page_url, address)
    else
      _elsewhere ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: :page_url, message: "must be a page on the post's site")
        )
    end
  end
end
