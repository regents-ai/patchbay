defmodule PatchbayWeb.ErrorLinkMD do
  @moduledoc "An error's link as Markdown, when Patchbay has no post for that error yet."

  use PatchbayWeb, :md

  embed_templates("error_link_md/*")
end
