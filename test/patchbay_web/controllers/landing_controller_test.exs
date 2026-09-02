defmodule PatchbayWeb.LandingControllerTest do
  use PatchbayWeb.ConnCase, async: true

  test "GET / is the front door and does not open a room", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~
             "A website that catches its own broken agent tool, proves it, and repairs it while the agent waits."

    assert html =~ "Built by Regents Labs for the OpenAI WebMCP Challenge."
    assert html =~ "https://github.com/regents-ai/patchbay"
  end

  test "the primary button opens the room entrance and the secondary link the board", %{
    conn: conn
  } do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~
             ~r{<a[^>]+href="/webmcp/rooms/skill-uplift"[^>]*>\s*Open your repair room\s*</a>}

    assert html =~ ~r{<a[^>]+href="/sites"[^>]*>\s*See what agents reported\s*</a>}
  end

  test "the front door names every tool the page offers an agent", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for name <-
          ~w(get_patchbay_room_state verify_skill_uplift_goal uplift_current_skill_v1 uplift_current_skill_v2) do
      assert html =~ name
    end
  end

  test "the loop is spelled out in five steps", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "The agent calls the tool"
    assert html =~ "The page proves the failure"
    assert html =~ "The report is filed with that receipt"
    assert html =~ "Patchbay repairs and swaps the tool"
    assert html =~ "The agent retries, and it is verified"
  end

  test "the page carries its description and sharing tags", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~r{<meta name="description" content="Patchbay is a website that catches}
    assert html =~ ~s{<meta property="og:type" content="website">}
    assert html =~ ~s{<meta property="og:url" content="https://patchbay.help">}
    assert html =~ ~s{<meta property="og:title" content="Patchbay">}
    assert html =~ ~s{<meta name="twitter:card" content="summary">}
    assert html =~ ~s{<link rel="icon" href="/favicon.svg" type="image/svg+xml">}
    assert html =~ ~r{A site that repairs its own agent tool\s*· Patchbay</title>}
  end

  test "the first thing on any page is a link to the content", %{conn: conn} do
    # Both pages are asserted because the link belongs to the shared root
    # layout: if it only showed up on the front page it would be the wrong fix.
    for path <- [~p"/", ~p"/sites"] do
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
