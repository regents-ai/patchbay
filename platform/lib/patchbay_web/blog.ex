defmodule PatchbayWeb.Blog do
  @moduledoc """
  This product's repository-owned, release-safe blog catalog. The posts about
  crypto, wallets or money are patchbay.help's: the open address
  (`PatchbayWeb.SiteEdition`) leaves them out of its blog, the blog's
  Markdown and its sitemap, and answers their addresses as missing pages.
  """
  use RegentBlog.Catalog, root: Path.expand("../../../blog", __DIR__)

  # By slug: the shared catalog keeps only its own front matter.
  @main_only ~w(agent-wallet-bench-v7)

  @doc "The published posts at `edition`'s address, newest first."
  def all(:main), do: all()
  def all(:open), do: Enum.reject(all(), &(&1.slug in @main_only))

  @doc "One published post at `edition`'s address, or nil."
  def get(slug, edition), do: Enum.find(all(edition), &(&1.slug == slug))
end
