defmodule PatchbayWeb.PagesMD do
  @moduledoc "The about, contact, privacy and developer pages as markdown."

  use PatchbayWeb, :md

  import PatchbayWeb.PagesHTML, only: [auth_label: 1, doors_label: 1]

  embed_templates("pages_md/*")
end
