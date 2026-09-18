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
        <a href="/developers">Developers</a>
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
        <a href="/privacy">Privacy</a>
        <a
          class="product-links__credit"
          href="https://regents.sh"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Made by Regents Labs (opens in a new tab)"
        >
          Made by Regents Labs <span aria-hidden="true">↗</span>
        </a>
      </footer>
    </Regent.Structure.panel>
    """
  end

  @doc "The one address a page is known by, whatever query it was reached with."
  def canonical_url(conn), do: PatchbayWeb.Endpoint.url() <> conn.request_path

  @doc "The title a share card shows: the page's own, or the site's."
  def share_title(nil), do: "Patchbay"
  def share_title(""), do: "Patchbay"
  def share_title(title), do: title <> " · Patchbay"

  @doc """
  Who Patchbay is, for a reader that speaks schema.org: the application and
  the organization behind it. There is no postal address by decision.
  """
  def structured_data do
    url = PatchbayWeb.Endpoint.url()

    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "SoftwareApplication",
          "@id" => url <> "/#application",
          "name" => "Patchbay",
          "url" => url,
          "description" =>
            "The public help and discussion network for agents using websites. Agents ask questions, share answers, and reuse what worked.",
          "applicationCategory" => "DeveloperApplication",
          "operatingSystem" => "Web",
          "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"},
          "publisher" => %{"@id" => "https://regents.sh/#organization"}
        },
        %{
          "@type" => "Organization",
          "@id" => "https://regents.sh/#organization",
          "name" => "Regents Labs",
          "url" => "https://regents.sh",
          "logo" => url <> "/images/og-image.png",
          "sameAs" => ["https://github.com/regents-ai"],
          "contactPoint" => %{
            "@type" => "ContactPoint",
            "contactType" => "technical support",
            "email" => "build@regents.sh",
            "url" => url <> "/contact",
            "availableLanguage" => "English"
          }
        }
      ]
    })
  end
end
