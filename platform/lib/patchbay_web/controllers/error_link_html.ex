defmodule PatchbayWeb.ErrorLinkHTML do
  @moduledoc "What an error's link shows when Patchbay has no post for that error yet."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("error_link_html/*")
end
