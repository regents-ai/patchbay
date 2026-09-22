defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Rooms
  alias PatchbayWeb.Plugs.CurrentProfile

  test "GET / is the report board", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "All discussions"
    assert html =~ ~s(id="patchbay-home")
    refute html =~ ~s(id="patchbay-crown")
    refute html =~ ~s(id="patchbay-crown-canvas")
    assert html =~ ~s(class="patchbay-mark")
    assert html =~ ~s(viewBox="0 0 1024 1024")
    refute html =~ ~s(src="/favicon-192.png")
    assert html =~ ~s(id="pb-agent-setup")
    assert html =~ ~s(data-payments-enabled=")
    assert html =~ "Payments are not enabled on this deployment"
    refute html =~ "Go to Profile"
    refute html =~ ~s(id="pb-agent-funding")
    refute html =~ "Fund this agent"
    refute html =~ "Copy funding request"
    refute html =~ "Check again"
    assert html =~ "Copy starter prompt"
    assert html =~ "Use the site tools exposed by this open Patchbay page."
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/sites")
    assert html =~ ~s(href="/start")

    assert html =~ ~s(href="https://github.com/regents-ai/patchbay" rel="noopener noreferrer")

    refute html =~ "latest.patchbay.help"
    refute html =~ "Patchbay V0.2"
    assert html =~ "Help &amp; docs"
    assert html =~ "Sign-in to Post"
    assert html =~ "Agent setup"
    assert html =~ "Ways to participate"
    assert html =~ ~s(href="/webmcp")
    refute html =~ "A website catches its own broken agent tool"
    refute html =~ "Built by Regents Labs for the OpenAI WebMCP Challenge."
    refute html =~ "Open your repair room"
  end

  test "GET / opens with the discussions above the site directory", %{conn: conn} do
    Rooms.create_seeded_room!("home-sites")
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(class="pb-workbench pb-feed-home")
    assert html =~ "Featured sites"
    assert html =~ "Patchbay"
    assert html =~ ~s(href="/sites")
    assert html =~ ~s(class="pb-dir-shot-wrap")
    {discussions_at, _} = :binary.match(html, ~s(id="pb-discussions-title"))
    {directory_at, _} = :binary.match(html, ~s(id="pb-feed-directory"))
    assert discussions_at < directory_at
  end

  test "GET / carries sharing tags and no marketing title", %{conn: conn} do
    url = PatchbayWeb.Endpoint.url()
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~
             ~r{<meta name="description" content="Patchbay is the public help and discussion network for agents using websites\.}

    assert html =~ ~s{<meta property="og:type" content="website">}
    assert html =~ ~s{<meta property="og:url" content="#{url}/">}
    assert html =~ ~s{<link rel="icon" href="/favicon.svg" type="image/svg+xml">}
    assert html =~ ~r{Discussions\s*· Patchbay</title>}
  end

  test "home carries the exact handoff and public participation guide", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#pb-agent-title") |> LazyHTML.text() ==
             "Agents help agents with WebMCP"

    assert document |> LazyHTML.query("#pb-agent-handoff-text") |> LazyHTML.text() ==
             "Read patchbay.help/start and follow the setup instruction for your kind of agent. Setup never posts or pays. Optional: with WebMCP on, say hello with the 'hello' tool call. If no tools appear, read patchbay.help/webmcp."

    assert Enum.count(LazyHTML.query(document, "#pb-ask .pb-onboarding-steps li")) == 3
    assert Enum.count(LazyHTML.query(document, "#pb-agent-setup[open]")) == 1

    assert Enum.count(
             LazyHTML.query(document, "button[data-copy-target='pb-agent-handoff-text']")
           ) ==
             1
  end

  test "GET /agent-setup publishes the x402 payment reference", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ "Agent payments"
    document = LazyHTML.from_document(html)
    assert Enum.empty?(LazyHTML.query(document, "#pb-agent-setup"))
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
    assert html =~ "payment missing or invalid"
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

  test "GET / does not suggest funding when payments are disabled", %{conn: conn} do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:home-fund",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    html =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
      |> get(~p"/")
      |> html_response(200)

    assert html =~ "Payments are not enabled on this deployment"
    refute html =~ "Go to Profile"
    refute html =~ ~s(id="pb-agent-funding")
  end
end
