defmodule PatchbayWeb.Forum.SiteFindingsTest do
  @moduledoc """
  A site's page shows what Patchbay read from the site itself: the WebMCP
  tools on its front page, its MCP servers and the files agents read. Checks
  from before kept code and packages found elsewhere, some only named like
  the site, and which lists could not be searched; none of that shows on the
  page, in its Markdown or in the site list's JSON.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum

  @domain "openai.com"
  @server "https://openai.com/mcp"
  @llms "https://openai.com/llms.txt"
  @code_urls [
    "https://github.com/openai/openai-node",
    "https://www.npmjs.com/package/openai",
    "https://github.com/someone/openai-clone"
  ]

  # A finished check as checks before this one kept it.
  setup do
    {:ok, check} = Forum.request_site_check(@domain)

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(
      check,
      %{
        findings: %{
          "webmcp" => [%{"name" => "search_openai", "description" => "Search OpenAI's site."}],
          "servers" => [
            %{"url" => @server, "answered" => true, "sign_in" => true, "tools" => []}
          ],
          "files" => [%{"kind" => "llms_txt", "url" => @llms, "title" => nil}],
          "code" => [
            code("github", "openai/openai-node", Enum.at(@code_urls, 0), true),
            code("npm", "openai", Enum.at(@code_urls, 1), true),
            code("github", "someone/openai-clone", Enum.at(@code_urls, 2), false)
          ],
          "unsearched" => ["npm"],
          "directory" => %{}
        },
        page_url: "https://openai.com/"
      },
      authorize?: false
    )

    :ok
  end

  defp code(source, name, url, from_site?),
    do: %{"source" => source, "name" => name, "url" => url, "from_site" => from_site?}

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  test "the page shows what was read from the site, and no code or package found elsewhere",
       %{conn: conn} do
    html = conn |> get("/" <> @domain) |> html_response(200)
    page = LazyHTML.from_document(html)

    assert texts(page, "#pb-site-agents .pb-site-check-group h3") ==
             ["WebMCP tools", "MCP servers", "Agent files"]

    assert texts(page, "#pb-site-tools .pb-tool-row-name") == ["search_openai"]
    assert texts(page, "#pb-site-agents .pb-site-check-list code") == [@server]

    assert [_file] =
             page |> LazyHTML.query("#pb-site-agents a[href='#{@llms}']") |> Enum.to_list()

    for url <- @code_urls, do: refute(html =~ url)
    # Nothing is said about lists that could not be searched.
    assert texts(page, ".pb-site-agent-content > p.pb-site-check-note") == []
  end

  test "the page's Markdown shows what was read from the site, and no code or package list",
       %{conn: conn} do
    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/" <> @domain)
      |> response(200)

    [_before, rest] = String.split(markdown, "## What agents can use on #{@domain}", parts: 2)
    [section | _later] = String.split(rest, "\n## ", parts: 2)

    assert section =~ "`search_openai`"
    assert section =~ @server
    assert section =~ @llms

    assert for(["### " <> heading] <- Regex.scan(~r/^### .+$/m, section), do: heading) ==
             ["WebMCP tools on its page", "MCP servers", "Files for agents"]

    # Neither a package list's entries nor its name.
    refute section =~ ~r/github|npm/i
  end

  test "the site list's JSON carries no code or package found elsewhere", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/sites?q=openai")
      |> json_response(200)

    assert Enum.any?(body["sites"], &(&1["origin"] == @domain))
    for url <- @code_urls, do: refute(Jason.encode!(body) =~ url)
  end
end
