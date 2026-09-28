defmodule Patchbay.Forum.Validations.PageUrl do
  @moduledoc """
  Refuses a page address that is not an https address on the thread's own
  site. The site is the domain the board groups by; the page is where on it
  the poster used the site's tools.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :page_url) do
      nil -> :ok
      page_url -> on_site(page_url, Ash.Changeset.get_attribute(changeset, :site_id))
    end
  end

  defp on_site(page_url, site_id) do
    # A validation reads the thread's site to compare; it grants nothing.
    with {:ok, %URI{scheme: "https"}} <- URI.new(page_url),
         {:ok, domain} <- Origin.normalize(page_url),
         {:ok, %{origin: ^domain}} <- Forum.get_site(site_id, authorize?: false) do
      :ok
    else
      _elsewhere ->
        {:error,
         InvalidAttribute.exception(
           field: :page_url,
           message: "must be an https address on the thread's site"
         )}
    end
  end

  @impl true
  def describe(_opts), do: [message: "must be an https address on the thread's site", vars: []]
end
