defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Rooms
  alias PatchbayWeb.Plugs.CurrentProfile

  test "GET / is the report board", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Reports from browser agents"
    assert html =~ ~s(id="patchbay-home")
    refute html =~ ~s(id="patchbay-crown")
    refute html =~ ~s(id="patchbay-crown-canvas")
    assert html =~ ~s(class="patchbay-mark")
    assert html =~ ~s(viewBox="0 0 1024 1024")
    refute html =~ ~s(src="/favicon-192.png")
    assert html =~ ~s(id="pb-agent-setup")
    assert html =~ ~s(data-payments-enabled=")
    assert html =~ "Fund your agent with USDC to unlock more WebMCP Tools"
    assert html =~ "Go to Profile"
    assert html =~ ~s(href="#pb-account")
    refute html =~ ~s(id="pb-agent-funding")
    refute html =~ "Fund this agent"
    refute html =~ "Copy funding request"
    refute html =~ "Check again"
    assert html =~ "Copy starter prompt"
    assert html =~ "Use the site tools exposed by this open Patchbay page."
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/sites")
    assert html =~ ~s(href="/webmcp/rooms/skill-uplift")

    assert html =~
             ~s(href="https://github.com/regents-ai/patchbay" target="_blank" rel="noreferrer")

    refute html =~ "latest.patchbay.help"
    refute html =~ "Patchbay V0.2"
    assert html =~ "Live demo"
    assert html =~ "Sign-in to Post"
    assert html =~ "Agent setup"
    assert html =~ "How reports work"
    assert html =~ ~s(href="/agent-setup")
    refute html =~ "A website catches its own broken agent tool"
    refute html =~ "Built by Regents Labs for the OpenAI WebMCP Challenge."
    refute html =~ "Open your repair room"
  end

  test "GET / leads with the site grid", %{conn: conn} do
    Rooms.create_seeded_room!("home-sites")
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(class="pb-dir-grid")
    assert html =~ ~s(href="/sites/patchbay")
    assert html =~ ~s(class="pb-dir-logo")
    refute html =~ ~s(class="pb-dir-shot")
  end

  test "GET / carries sharing tags and no marketing title", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~r{<meta name="description" content="Patchbay is a website that catches}
    assert html =~ ~s{<meta property="og:type" content="website">}
    assert html =~ ~s{<meta property="og:url" content="https://patchbay.help">}
    assert html =~ ~s{<link rel="icon" href="/favicon.svg" type="image/svg+xml">}
    assert html =~ ~r{WebMCP directory\s*· Patchbay</title>}
  end

  test "GET /agent-setup publishes WebMCP, x402, and runtime anchors", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ "Use Patchbay with an agent"
    assert html =~ ~s(id="webmcp")
    assert html =~ ~s(id="x402")
    assert html =~ ~s(id="hermes")
    assert html =~ ~s(id="codex-cli")
    assert html =~ ~s(id="claude-code")
    assert html =~ ~s(href="#webmcp")
    assert html =~ ~s(href="#x402")
    assert html =~ "tip_agent"
    assert html =~ "post_priority_report"
    assert html =~ "x402-paid WebMCP tools"
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
    assert html =~ "ChatGPT desktop"
    assert html =~ "claude --chrome"
    assert html =~ "target configuration"
    assert html =~ "Keep wallet keys inside the wallet"
    refute html =~ "npm install patchbay-webmcp-bridge"
    refute html =~ "x402-gated"
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/webmcp/rooms/skill-uplift")
  end

  test "GET /agent-setup includes the ops FAQ", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ ~s(id="faq")
    assert html =~ ~s(href="#faq")
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

  test "GET / sends a signed-in visitor to their profile to fund", %{conn: conn} do
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

    assert html =~ "Fund your agent with USDC to unlock more WebMCP Tools"
    assert html =~ "Go to Profile"
    assert html =~ ~s(href="/agents/#{profile.public_id}")
    refute html =~ ~s(id="pb-agent-funding")
  end
end
