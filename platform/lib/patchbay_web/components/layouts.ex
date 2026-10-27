defmodule PatchbayWeb.Layouts do
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [site_nav: 1]

  embed_templates("layouts/*")

  # REGENT on Base, the token every Regent site names in its footer.
  @buy_regent "https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"

  @doc """
  The footer of every page, the same on every Regent site: the social links,
  Buy $REGENT, the site's documents and its two plain-text guides for agents, which
  open in the browser's popover from "Agent guide". It sits at the foot of the
  screen however short the page is. The theme switch stays in the header, which
  every page has.
  """
  def product_links(assigns) do
    assigns = assign(assigns, :buy_regent, @buy_regent)

    ~H"""
    <footer class="regent-footer">
      <div class="regent-footer__social">
        <a
          href="https://x.com/regents_sh"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Patchbay on X"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
            <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
          </svg>
        </a>
        <a
          href="https://github.com/regents-ai"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Patchbay on GitHub"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
            <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
          </svg>
        </a>
      </div>
      <nav class="regent-footer__links" aria-label="About Patchbay">
        <a href={@buy_regent} target="_blank" rel="noopener noreferrer">Buy $REGENT</a>
        <a href={~p"/about"}>About</a>
        <a href={~p"/docs"}>Developer docs</a>
        <button type="button" class="regent-footer__guide" popovertarget="footer-agent-guide">
          Agent guide
        </button>
        <div id="footer-agent-guide" class="rg-tip-body regent-footer__guide-body" popover>
          <p>Give your agent one of these.</p>
          <a href={~p"/agents.md"}>What agents can do here</a>
          <a href={~p"/llms.txt"}>The whole site in brief</a>
        </div>
        <a href={~p"/contact"}>Contact</a>
        <span class="regent-footer__legal">
          <a href={~p"/privacy"}>Privacy policy</a>
          <a href={~p"/terms"}>Terms of use</a>
        </span>
      </nav>
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end

  @doc """
  Who Patchbay is, for a reader that speaks schema.org (the website, the
  application and the organization behind both; no postal address, by
  decision), then the nodes the page holds: a page's `page_data` assign, built
  with `Regent.StructuredData`.
  """
  def structured_data(page_nodes), do: Regent.StructuredData.graph(site_graph(), page_nodes)

  @doc "The `@id` of the organization behind Patchbay, a blog post's publisher."
  def organization_id, do: "https://regents.sh/#organization"

  defp site_graph do
    url = PatchbayWeb.Endpoint.url()

    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "WebSite",
          "@id" => url <> "/#website",
          "name" => "Patchbay",
          "url" => url,
          "publisher" => %{"@id" => organization_id()}
        },
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
          "publisher" => %{"@id" => organization_id()}
        },
        %{
          "@type" => "Organization",
          "@id" => organization_id(),
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
    }
  end
end
