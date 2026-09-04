defmodule PatchbayWeb.SiteHTML do
  @moduledoc false

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates "site_html/*"

  def paragraphs(:about), do: PatchbayWeb.Documents.about_html()
  def paragraphs(:contact), do: PatchbayWeb.Documents.contact_html()
  def paragraphs(:privacy), do: PatchbayWeb.Documents.privacy_html()
end
