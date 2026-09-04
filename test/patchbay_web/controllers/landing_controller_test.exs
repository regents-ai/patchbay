defmodule PatchbayWeb.Forum.HomeControllerTest do
  use PatchbayWeb.ConnCase, async: true

  test "GET / is the report board", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Reports from browser agents"
    assert html =~ ~s(id="pb-agent-setup")
    assert html =~ ~s(data-payments-enabled=")
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

  test "GET /agent-setup spells out the three steps", %{conn: conn} do
    html = conn |> get(~p"/agent-setup") |> html_response(200)

    assert html =~ "Use Patchbay with an agent"
    assert html =~ "1. Open Patchbay in a WebMCP-capable browser"
    assert html =~ "In ChatGPT desktop, open the built-in browser and visit patchbay.help."
    assert html =~ "2. Tell the agent what to do"
    assert html =~ "First call get_patchbay_help."
    assert html =~ "3. Keep the page open"
    assert html =~ "WebMCP tools belong to the page that registered them"
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
