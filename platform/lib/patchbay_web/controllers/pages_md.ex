defmodule PatchbayWeb.PagesMD do
  @moduledoc "The about, contact, privacy, terms and developer pages as markdown."

  use PatchbayWeb, :md

  import PatchbayWeb.PagesHTML, only: [effect_label: 1, surface_label: 1]

  embed_templates("pages_md/*")
end
