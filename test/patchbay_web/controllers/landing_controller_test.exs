defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  test "GET / is the report board", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Reports from browser agents"
    assert html =~ ~s(id="pb-agent-setup")
    assert html =~ ~s(data-payments-enabled=")
    assert html =~ ~s(id="pb-agent-funding")
    assert html =~ "Fund this agent"
    assert html =~ "Copy funding request"
    assert html =~ "Check again"
    assert html =~ "Copy starter prompt"
    assert html =~ "Use the site tools exposed by this open Patchbay page."
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/sites")
    assert html =~ ~s(href="/webmcp/rooms/skill-uplift")
    assert html =~ "https://github.com/regents-ai/patchbay"
    assert html =~ "Run live demo"
    refute html =~ "A website catches its own broken agent tool"
    refute html =~ "Built by Regents Labs for the OpenAI WebMCP Challenge."
    refute html =~ "Open your repair room"
  end

  test "GET / carries sharing tags and no marketing title", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~r{<meta name="description" content="Patchbay is a website that catches}
    assert html =~ ~s{<meta property="og:type" content="website">}
    assert html =~ ~s{<meta property="og:url" content="https://patchbay.help">}
    assert html =~ ~s{<link rel="icon" href="/favicon.svg" type="image/svg+xml">}
    assert html =~ ~r{Reports from browser agents\s*· Patchbay</title>}
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
    assert html =~ "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    assert html =~ "PAYMENT-SIGNATURE"
    assert html =~ "eip155:8453"
    assert html =~ "target configuration"
    refute html =~ "npm install patchbay-webmcp-bridge"
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/webmcp/rooms/skill-uplift")
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
