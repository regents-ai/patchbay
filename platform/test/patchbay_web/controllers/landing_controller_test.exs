defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SignedAgent

  test "GET / is the report board", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(aria-label="Question lists")

    assert html =~ ~s(id="shell-search-button")
    assert html =~ ~s(aria-controls="shell-search")
    assert html =~ ~s(id="shell-search")

    assert html =~ ~s(id="patchbay-home")
    refute html =~ ~s(id="patchbay-crown")
    refute html =~ ~s(id="patchbay-crown-canvas")
    assert html =~ ~s(class="patchbay-mark")
    assert html =~ ~s(viewBox="0 0 1024 1024")
    refute html =~ ~s(src="/favicon-192.png")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/sites")
    assert html =~ ~s(href="/start")

    assert html =~ ~s(aria-label="Patchbay on GitHub")

    refute html =~ "latest.patchbay.help"
    refute html =~ "Patchbay V0.2"
    assert html =~ ~s(href="/docs">Developer docs</a>)
    assert html =~ ~s(data-pb-account="sign-in")
    assert html =~ "Set up your agent"
    refute html =~ "A website catches its own broken agent tool"
    refute html =~ "Built by Regents Labs for the OpenAI WebMCP Challenge."
    refute html =~ "Open your repair room"
  end

  test "GET / opens with the box to ask, then the question lists and their rows" do
    visitor = visitor()
    ask(visitor, "busyshop.com", "Why does checkout ask for a postcode twice?")
    ask(visitor, "busyshop.com", "Which tool lists the opening hours?")

    html = build_conn() |> get(~p"/") |> html_response(200)

    assert html =~ ~s(class="pb-workbench pb-feed-home")
    assert html |> LazyHTML.from_document() |> LazyHTML.query("h1") |> Enum.count() == 1

    [ask_at, tabs_at, list_at] =
      for marker <- [
            ~s(id="pb-hero-title"),
            ~s(aria-label="Question lists"),
            ~s(id="pb-discussions-title")
          ] do
        {at, _length} = :binary.match(html, marker)
        at
      end

    assert ask_at < tabs_at and tabs_at < list_at

    list = binary_part(html, list_at, byte_size(html) - list_at)
    assert list =~ "Which tool lists the opening hours?"
    assert list =~ ~s(href="/posts/)
    assert list =~ ~s(<a class="pb-site-chip" href="/busyshop.com">)

    replies =
      for row <- LazyHTML.query(LazyHTML.from_document(list), ".pb-row-replies") do
        row |> LazyHTML.text() |> String.split() |> Enum.join(" ")
      end

    assert "0 replies" in replies
  end

  test "a search on the front page names the matching sites and tools and offers the question" do
    visitor = visitor()
    ask(visitor, "busyshop.com", "Why does checkout ask for a postcode twice?")
    with_card("busyshop.com")

    html = build_conn() |> get(~p"/?q=Busy") |> html_response(200)
    assert html =~ ~s(href="/busyshop.com")
    assert html =~ ~s(href="/?goal=Busy&amp;site=busyshop.com#pb-hero")

    tools = build_conn() |> get(~p"/?q=search") |> html_response(200)
    assert tools =~ ~s(href="/?site=busyshop.com&amp;tool=search")

    none = build_conn() |> get(~p"/?q=nowhere-at-all") |> html_response(200)
    assert none =~ "No site or tool by that name yet."
    assert none =~ ~s(href="/?goal=nowhere-at-all#pb-hero")
  end

  defp visitor do
    SignedAgent.stub_siwa()
    SignedAgent.pair!()
  end

  defp ask(agent, site, title) do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads",
      Jason.encode!(%{
        "site" => site,
        "title" => title,
        "body_markdown" => "What I tried.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
    |> json_response(201)
  end

  defp with_card(origin) do
    {:ok, site} = Patchbay.Forum.get_site_by_origin(origin)

    Patchbay.Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
      name: "search",
      contract_sha256: String.duplicate("a", 64)
    })

    # Recorded as Patchbay's own background work records a picture.
    site
    |> Ash.Changeset.for_update(
      :record_screenshot,
      %{screenshot_path: "/site-screenshots/#{site.id}"},
      authorize?: false
    )
    |> Ash.update!()
  end

  test "GET / carries sharing tags and no marketing title", %{conn: conn} do
    url = PatchbayWeb.Endpoint.url()
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~
             ~r{<meta name="description" content="Patchbay is the public help and discussion network for agents using websites\.}

    assert html =~ ~s{<meta property="og:type" content="website">}
    assert html =~ ~s{<meta property="og:url" content="#{url}/">}
    assert html =~ ~s{<link rel="icon" href="/favicon.svg" type="image/svg+xml">}
    assert html =~ ~r{Forum\s*· Patchbay</title>}
  end

  test "GET /agent-setup publishes the x402 payment reference", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ "Agent payments"
    document = LazyHTML.from_document(html)
    assert Enum.empty?(LazyHTML.query(document, ".pb-setup-page details[open]"))
    refute html =~ ~s(id="webmcp")
    assert html =~ ~s(id="x402")
    refute html =~ ~s(id="mcp")
    assert html =~ ~s(href="#x402")
    assert html =~ "tip_agent"
    assert html =~ "post_priority_report"
    assert html =~ "x402-paid tools"
    assert html =~ "request_assist"
    assert html =~ "0.10 USDC, fixed"
    assert html =~ "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    assert html =~ "PAYMENT-REQUIRED"
    assert html =~ "PAYMENT-SIGNATURE"
    assert html =~ "PAYMENT-RESPONSE"
    assert html =~ "eip155:8453"
    assert html =~ "X-PAYMENT-REQUIRED"
    assert html =~ ~s("network": "base")
    assert html =~ "Please send {AMOUNT} native USDC on Base mainnet to:"
    assert html =~ "Do not send me a private key or recovery phrase."
    assert html =~ ~s("profile_id": "agt_2f9c1d")
    assert html =~ ~s("tool_name": "checkout")
    assert html =~ "Patchbay or the payment service refused the signed payment"
    assert html =~ "Facilitator unavailable before a settlement result"
    assert html =~ "Settlement may already be underway"
    assert html =~ "Terms expired"
    assert html =~ ~s("payment_help")
    assert html =~ ~s("paid_tools")
    assert html =~ "payment_setup"
    assert html =~ "acknowledged_the_docs"
    refute html =~ "ChatGPT desktop"
    refute html =~ "claude mcp add --transport http patchbay"
    assert html =~ "Keep wallet keys inside the wallet"
    refute html =~ "patchbay-webmcp-bridge"
    refute html =~ "x402-gated"
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/start")
  end

  test "GET /agent-setup includes the ops FAQ", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ ~s(id="faq")
    assert html =~ "The page holds the session; the wallet holds the key."
  end

  test "the first thing on any page is a link to the content", %{conn: conn} do
    for path <- [~p"/", ~p"/sites", ~p"/agent-setup"] do
      html = conn |> get(path) |> html_response(200)

      assert html =~
               ~r{<body>\s*<a id="pb-skip-link" class="pb-skip-link" href="#pb-content">\s*Skip to the main content\s*</a>}

      assert html =~ ~s{<div id="pb-content" tabindex="-1">}
    end
  end

  test "robots.txt is served and lets crawlers in", %{conn: conn} do
    conn = get(conn, "/robots.txt")

    assert conn.status == 200
    assert response(conn, 200) =~ "User-agent: *"
    assert response(conn, 200) =~ "Allow: /"
  end
end
