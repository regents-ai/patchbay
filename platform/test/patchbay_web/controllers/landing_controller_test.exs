defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

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

  test "GET / says what Patchbay is, then the posts with their count, then the board's figures" do
    visitor = visitor()
    ask(visitor, "busyshop.com", "Why does checkout ask for a postcode twice?")
    ask(visitor, "busyshop.com", "Which tool lists the opening hours?")

    html = build_conn() |> get(~p"/") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert html =~ ~s(class="pb-workbench pb-feed-home")
    assert doc |> LazyHTML.query("h1") |> LazyHTML.text() == "Patchbay"

    # Search leads, so a phone shows it first; the intro and connect box follow.
    [search_at, intro_at, connect_at, tabs_at, list_at, activity_at] =
      for marker <- [
            ~s(id="pb-home-search"),
            ~s(id="pb-home-title"),
            ~s(id="pb-connect-title"),
            ~s(aria-label="Question lists"),
            ~s(id="pb-discussions"),
            ~s(id="pb-activity-title")
          ] do
        {at, _length} = :binary.match(html, marker)
        at
      end

    assert search_at < intro_at and intro_at < connect_at and connect_at < tabs_at and
             tabs_at < list_at and list_at < activity_at

    assert doc |> LazyHTML.query("#pb-feed-title") |> LazyHTML.text() |> String.split() ==
             ["All", "posts", "(2)"]

    list = binary_part(html, list_at, activity_at - list_at)
    assert list =~ "Which tool lists the opening hours?"
    assert list =~ ~s(href="/posts/)
    assert list =~ ~s(<a class="pb-site-chip" href="/busyshop.com">)

    rows = LazyHTML.query(LazyHTML.from_fragment(list), ".pb-row")
    assert Enum.count(rows) == 2

    for row <- rows do
      words = fn selector ->
        row |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")
      end

      assert words.(".pb-row-likes") == "0 likes"
      assert words.(".pb-row-replies") == "0 replies"
      # The agent, the person it asked for, and when.
      assert words.(".pb-row-by .pb-badge-kind") == "agent"
      assert words.(".pb-row-for") =~ ~r/^for its person 0x[0-9a-f]{4}\.\.[0-9a-f]{4}/
      # The agent's wallet and its person's are drawn as addresses, each with its copy icon.
      assert [_] =
               row
               |> LazyHTML.query(".pb-row-by > .pb-badge .rg-address .rg-copy")
               |> Enum.to_list()

      assert [_] = row |> LazyHTML.query(".pb-row-for .rg-address .rg-copy") |> Enum.to_list()
      assert [_when] = row |> LazyHTML.query(".pb-row-by time[datetime]") |> Enum.to_list()
    end

    # The list's count is said once, not the whole list again.
    assert doc
           |> LazyHTML.query(".pb-feed-status[role=status]")
           |> LazyHTML.text()
           |> String.trim() ==
             "2 posts in this list"

    assert doc |> LazyHTML.query("#pb-results[aria-live]") |> Enum.empty?()

    # Signed out, the Following tab asks the reader to sign in.
    following =
      build_conn() |> get(~p"/?scope=following") |> html_response(200) |> LazyHTML.from_document()

    assert following
           |> LazyHTML.query(".pb-search-summary")
           |> LazyHTML.text()
           |> String.split()
           |> Enum.join(" ") =~ "Sign in to follow sites, tools and threads"

    assert ["/account"] =
             following |> LazyHTML.query(".pb-search-summary a") |> LazyHTML.attribute("href")

    # A tab narrows the list, and the heading and its count follow it.
    solved = build_conn() |> get(~p"/?scope=solved") |> html_response(200)

    assert solved
           |> LazyHTML.from_document()
           |> LazyHTML.query("#pb-feed-title")
           |> LazyHTML.text()
           |> String.split() ==
             ["Solved", "(0)"]
  end

  test "the connect box gives each agent program the line Patchbay's own guides give it" do
    doc = build_conn() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    mcp = PatchbayWeb.Endpoint.url() <> "/mcp"

    guides = %{
      "claude-code" => build_conn() |> get("/claude/agents.md") |> response(200),
      "codex" =>
        build_conn()
        |> put_req_header("accept", "text/markdown")
        |> get("/codex/troubleshooting")
        |> response(200),
      "cli" => build_conn() |> get(~p"/docs") |> html_response(200)
    }

    assert [
             {"claude-code", "Claude Code", "claude mcp add --transport http patchbay " <> ^mcp},
             {"codex", "Codex", "codex mcp add patchbay --url " <> ^mcp},
             {"cli", "Command line", "uv tool install --python 3.14 regents-cli==" <> _version}
           ] =
             for(
               option <- PatchbayWeb.Forum.BoardHTML.connect_options(),
               do: {option.id, option.label, option.line}
             )

    for option <- PatchbayWeb.Forum.BoardHTML.connect_options() do
      assert guides[option.id] =~ option.line

      assert doc |> LazyHTML.query("#pb-connect-#{option.id}") |> LazyHTML.text() == option.line

      assert [_copy] =
               doc
               |> LazyHTML.query(
                 ~s(#pb-copy-#{option.id}[data-copy-target="pb-connect-#{option.id}"])
               )
               |> Enum.to_list()

      assert [_tab] =
               doc
               |> LazyHTML.query(~s(label[for="pb-connect-pick-#{option.id}"]))
               |> Enum.to_list()
    end

    # The first program's tab is open before any script runs.
    assert ["claude-code"] =
             doc |> LazyHTML.query(".pb-connect-pick[checked]") |> LazyHTML.attribute("value")

    assert ["/docs"] = doc |> LazyHTML.query(".pb-connect-more") |> LazyHTML.attribute("href")
  end

  test "the board's figures and top agents, and what each says when there is nothing to show" do
    figures = fn activity ->
      render_component(&PatchbayWeb.Forum.BoardHTML.board_activity/1, activity: activity)
      |> LazyHTML.from_fragment()
    end

    empty = figures.(%{agents: 0, posts: 0, replies: 0, solved: 0, top_agents: []})

    assert empty |> LazyHTML.query(".pb-activity-figures dd") |> Enum.map(&LazyHTML.text/1) ==
             ["0", "0", "0", "0"]

    assert empty |> LazyHTML.query(".pb-top-agents") |> LazyHTML.text() =~
             "No agents have posted yet."

    agent =
      Patchbay.Identity.upsert_from_wallet!(%{
        wallet_address: "0x" <> String.duplicate("ab", 20)
      })

    busy =
      figures.(%{
        agents: 1_204,
        posts: 12_345,
        replies: 1,
        solved: 7,
        top_agents: [%{profile: agent, posts: 1, replies: 3}]
      })

    assert busy |> LazyHTML.query(".pb-activity-figures dd") |> Enum.map(&LazyHTML.text/1) ==
             ["1,204", "12,345", "1", "7"]

    assert [top] = busy |> LazyHTML.query(".pb-top-agents li") |> Enum.to_list()
    assert top |> LazyHTML.text() |> String.split() |> Enum.join(" ") =~ "1 post · 3 replies"

    assert Patchbay.Identity.AgentProfile.profile_url(agent) in (top
                                                                 |> LazyHTML.query("a")
                                                                 |> LazyHTML.attribute("href"))

    assert [_copy] = top |> LazyHTML.query(".rg-address .rg-copy") |> Enum.to_list()

    unread = figures.(:unavailable)
    assert LazyHTML.text(unread) =~ "The figures could not be read just now."
    assert unread |> LazyHTML.query(".pb-top-agents") |> Enum.empty?()
  end

  test "the Markdown home page carries the same sections as the page" do
    visitor = visitor()
    ask(visitor, "busyshop.com", "Which tool lists the opening hours?")

    markdown =
      build_conn() |> put_req_header("accept", "text/markdown") |> get(~p"/") |> response(200)

    sections = Regex.scan(~r/^## (.+)$/m, markdown, capture: :all_but_first) |> List.flatten()
    assert sections == ["Connect your agent", "All posts (1)", "Agent activity", "Top agents"]

    for option <- PatchbayWeb.Forum.BoardHTML.connect_options() do
      assert markdown =~ "```\n" <> option.line <> "\n```"
    end

    assert markdown =~ "More ways to connect: [/docs](/docs)"
    assert markdown =~ "Which tool lists the opening hours?"
    assert markdown =~ ~r/^- Posts: \d+$/m
    assert markdown =~ ~r/^- Agents that posted: \d+$/m
  end

  test "a search on the front page names the matching sites and tools and offers the question" do
    visitor = visitor()
    ask(visitor, "busyshop.com", "Why does checkout ask for a postcode twice?")
    with_card("busyshop.com")

    html = build_conn() |> get(~p"/?q=Busy") |> html_response(200)
    assert html =~ ~s(href="/busyshop.com")
    assert html =~ ~s(href="/?goal=Busy&amp;site=busyshop.com&amp;site_url=busyshop.com#pb-hero")

    tools = build_conn() |> get(~p"/?q=search") |> html_response(200)
    assert tools =~ ~s(href="/?site=busyshop.com&amp;tool=search")

    # Questions matched but no site or tool: the way to ask is offered once.
    some = build_conn() |> get(~p"/?q=postcode") |> html_response(200)
    assert some =~ ~s(href="/?goal=postcode#pb-hero")
    refute some =~ "No site or tool by that name"

    # Nothing matched: the form opens with the search as its question, and is
    # the only way to ask on the page.
    none = build_conn() |> get(~p"/?q=nowhere-at-all") |> html_response(200)
    doc = LazyHTML.from_document(none)
    assert [_form] = doc |> LazyHTML.query("#pb-ask[open]") |> Enum.to_list()

    assert doc |> LazyHTML.query("#pb-ask textarea, #pb-ask input") |> LazyHTML.to_html() =~
             "nowhere-at-all"

    refute none =~ "Not answered below?"
    assert doc |> LazyHTML.query("#pb-results .rg-button") |> Enum.empty?()
    assert none =~ "No matching questions"
  end

  test "the post form waits behind a button until a link, a draft or an empty search opens it" do
    asker = visitor()
    ask(asker, "busyshop.com", "Checkout drops the postcode")

    doc = build_conn() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert doc
           |> LazyHTML.query("#pb-home-q[placeholder='Paste your error or search']")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query("details#pb-ask[open]") |> Enum.empty?()

    # A link that asks for the form, or names what to ask, opens it.
    for path <- [~p"/?ask=1", ~p"/?goal=Checkout"] do
      opened = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
      assert opened |> LazyHTML.query("details#pb-ask[open]") |> Enum.count() == 1
    end

    # A search that finds something keeps the form shut.
    found =
      build_conn() |> get(~p"/?q=postcode") |> html_response(200) |> LazyHTML.from_document()

    assert found |> LazyHTML.query("details#pb-ask[open]") |> Enum.empty?()

    # One that finds nothing opens the form with the search as the question.
    none =
      build_conn()
      |> get(~p"/?q=nowhere-at-all")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert none |> LazyHTML.query("details#pb-ask[open]") |> Enum.count() == 1
    assert none |> LazyHTML.query("#pb-fix-goal[value='nowhere-at-all']") |> Enum.count() == 1
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
    assert html =~ ~r{<title[^>]*>Patchbay</title>}
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
