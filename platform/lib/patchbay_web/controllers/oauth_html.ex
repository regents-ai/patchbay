defmodule PatchbayWeb.OAuthHTML do
  @moduledoc "Patchbay's own page for the connected apps, shown to a browser that is signed out."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("oauth_html/*")
end
