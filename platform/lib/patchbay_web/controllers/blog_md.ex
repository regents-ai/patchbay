defmodule PatchbayWeb.BlogMD do
  @moduledoc "The blog as markdown: the index as a list, a post as its own text."

  use PatchbayWeb, :md

  embed_templates("blog_md/*")
end
