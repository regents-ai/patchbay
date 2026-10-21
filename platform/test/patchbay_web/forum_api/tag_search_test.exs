defmodule PatchbayWeb.ForumAPI.TagSearchTest do
  @moduledoc """
  `search_threads` narrowed to one topic tag, over HTTP and the hosted MCP
  tools: only threads with that tag, on its own or beside other filters.
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum

  setup do
    site = Forum.register_site!("nodejs.org")
    tagged = ask!(site, "Node 24 refuses the eMudhra test host after an update", ["emudhra"])
    ask!(site, "Node 24 refuses the eMudhra test host behind a proxy", ["proxies"])
    %{tagged: tagged}
  end

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask!(site, title, tags) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: "What I changed and how I tested it.",
        topic_tags: tags
      },
      authorize?: false
    )
  end

  defp ids(body), do: Enum.map(body["results"], & &1["id"])

  test "a tag finds only the threads that carry it, alone or with other filters",
       %{conn: conn, tagged: tagged} do
    alone = json_response(get(conn, "/forum/search", %{"tag" => "emudhra"}), 200)
    assert ids(alone) == [tagged.id]
    assert alone["looked_for"]["tag"] == "emudhra"

    for extra <- [%{"sort" => "popular"}, %{"q" => "eMudhra"}, %{"origin" => "nodejs.org"}] do
      body = json_response(get(conn, "/forum/search", Map.put(extra, "tag", "emudhra")), 200)
      assert ids(body) == [tagged.id]
    end

    unknown = json_response(get(conn, "/forum/search", %{"tag" => "no-thread-has-this"}), 200)
    assert unknown["results"] == []
  end

  test "a tag that could never be one is refused", %{conn: conn} do
    for tag <- ["eMudhra", "e mudhra", "-emudhra", String.duplicate("a", 41)] do
      assert %{"error" => %{"code" => "invalid", "details" => [message]}} =
               json_response(get(conn, "/forum/search", %{"tag" => tag}), 422)

      assert message =~ "tag:"
    end
  end

  test "the hosted search_threads tool takes the tag", %{conn: conn, tagged: tagged} do
    %{"result" => result} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{"name" => "search_threads", "arguments" => %{"tag" => "emudhra"}}
        })
      )
      |> json_response(200)

    refute result["isError"]
    assert ids(result["structuredContent"]) == [tagged.id]
  end
end
