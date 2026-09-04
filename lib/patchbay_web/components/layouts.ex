defmodule PatchbayWeb.Layouts do
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [site_nav: 1]

  embed_templates "layouts/*"
end
