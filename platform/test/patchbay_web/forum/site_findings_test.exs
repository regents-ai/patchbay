defmodule PatchbayWeb.Forum.SiteFindingsTest do
  @moduledoc """
  A site's page shows what Patchbay read from the site itself, in three
  groups and nothing more: the WebMCP tools on its front page, its MCP
  servers and the files agents read. Its Markdown gives the same three.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum

  @domain "openai.com"
  @server "https://openai.com/mcp"
  @llms "https://openai.com/llms.txt"

  # A finished check, as Patchbay's check records it.
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
          "directory" => %{}
        },
        page_url: "https://openai.com/"
      },
      authorize?: false
    )

    :ok
  end

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  test "the page shows the site's tools, MCP servers and agent files, and no other group",
       %{conn: conn} do
    page = conn |> get("/" <> @domain) |> html_response(200) |> LazyHTML.from_document()

    assert texts(page, "#pb-site-agents .pb-site-check-group h3") ==
             ["WebMCP tools", "MCP servers", "Agent files"]

    assert texts(page, "#pb-site-tools .pb-tool-row-name") == ["search_openai"]
    assert texts(page, "#pb-site-agents .pb-site-check-list code") == [@server]

    assert [_file] =
             page |> LazyHTML.query("#pb-site-agents a[href='#{@llms}']") |> Enum.to_list()
  end

  test "the page's Markdown shows the same three groups", %{conn: conn} do
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
  end
end
