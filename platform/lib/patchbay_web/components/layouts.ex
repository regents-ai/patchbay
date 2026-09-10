defmodule PatchbayWeb.Layouts do
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [site_nav: 1]

  embed_templates("layouts/*")
  @doc "Product and source discovery without loading a browser integration."
  def product_links(assigns) do
    ~H"""
    <Regent.Structure.panel class="rg-support-panel pb-product-panel">
      <footer aria-label="Project links" class="product-links">
        <a href="https://github.com/regents-ai/patchbay" rel="noopener noreferrer">Star on GitHub</a>
        <a href="/llms.txt">Agent Start</a>
        <Regent.Primitives.disclosure id="pb-related-products" summary="Regents Labs">
          <nav aria-label="Related products" class="product-links__related">
            <a href="https://regents.sh">Regents</a>
            <a href="https://autolaunch.sh">Autolaunch</a>
            <a href="https://techtree.sh">Techtree</a>
          </nav>
        </Regent.Primitives.disclosure>
      </footer>
    </Regent.Structure.panel>
    """
  end
end
