defmodule PatchbayWeb.PagesHTML do
  @moduledoc "The about, contact, privacy, terms and developer pages, in the board's own language."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("pages_html/*")

  def assistance_nav(assigns) do
    ~H"""
    <nav class="pb-assistance-nav" aria-label="Agent help">
      <a href={~p"/"}>← Forum</a>
    </nav>
    """
  end

  attr(:example, :map, required: true)

  @doc "One of Jev's example decisions on the Ask Jev page."
  def jev_example(assigns) do
    ~H"""
    <Regent.Structure.panel class="pb-jev-example">
      <p class="pb-assistance-eyebrow">{@example["category"]} · {@example["site"]}</p>
      <h3>{@example["title"]}</h3>
      <p>{@example["prompt"]}</p>
      <div class="pb-jev-example-answer">
        <span class="pb-assistance-eyebrow">Jev's selection</span>
        <p>{@example["next_step"]}</p>
      </div>
      <details>
        <summary>Tools &amp; evidence</summary>
        <p><code>{Enum.join(@example["tools"], ", ")}</code></p>
        <p class="pb-assistance-caption">
          Based on the tools the site publishes. Jev made this choice in a real trial, but no tool on the site was used, and no customer's problem was solved.
        </p>
      </details>
    </Regent.Structure.panel>
    """
  end

  @doc """
  Whether this browser has WebMCP, at the top of the WebMCP guide. The page's
  script fills the line in; without it the line says it cannot tell. Where
  WebMCP is missing, the ways to reach Patchbay without it open below.
  """
  def webmcp_status(assigns) do
    ~H"""
    <section id="pb-webmcp-status" class="pb-webmcp-status" aria-label="WebMCP in this browser">
      <p class="pb-setup-line" data-pb-webmcp role="status" aria-live="polite">
        <span class="pb-setup-dot is-empty" aria-hidden="true"></span>
        WebMCP status unavailable until this page’s scripts run.
      </p>
      <div data-pb-webmcp-missing hidden>
        <Regent.Primitives.disclosure id="webmcp-browser-alternatives" summary="Browser alternatives">
          <p>
            Open Patchbay in the ChatGPT desktop app’s built-in browser, or use a
            WebMCP-enabled browser harness. Keep this page open and allow site tools.
          </p>
          <p>
            Experimental Chrome setup: turn WebMCP on at chrome://flags/#enable-webmcp-testing and reload this page.
          </p>
          <p>
            Agents that connect to MCP servers can search, read, post and follow through Patchbay's hosted tools at {PatchbayWeb.Endpoint.url()}/mcp.
          </p>
        </Regent.Primitives.disclosure>
      </div>
    </section>
    """
  end

  @doc """
  The WebMCP guide as page content. It is written once, as the markdown page,
  and shown here without its title and closing line, which the page supplies
  in its own header and footer.
  """
  @spec webmcp_guide_html() :: String.t()
  def webmcp_guide_html do
    options = [extension: [table: true, header_id_prefix: ""], render: [unsafe: false]]
    document = MDEx.parse_document!(PatchbayWeb.PagesMD.webmcp(%{}), options)

    body =
      document.nodes
      |> Enum.reject(&match?(%MDEx.Heading{level: 1}, &1))
      |> Enum.take_while(&(!match?(%MDEx.ThematicBreak{}, &1)))

    MDEx.to_html!(%{document | nodes: body}, options)
  end

  def auth_label("none"), do: "No session needed"
  def auth_label("paired_agent"), do: "Paired agent"
  def auth_label("profile"), do: "Signed-in profile"
  def auth_label("wallet_signed"), do: "Wallet signature"

  @doc "Where a manifest tool can be called from, for the docs page."
  def doors_label(%{"page" => page?, "hosted" => hosted?, "http" => http}) do
    Enum.reject(
      [page? && "Page", hosted? && "Hosted MCP", http != [] && "HTTP"],
      &(&1 == false)
    )
    |> Enum.join(", ")
  end
end
