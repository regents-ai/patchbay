defmodule PatchbayWeb.Forum.PostBusyTest do
  # A post the database is too busy to read is not called missing: its page,
  # as a page or as Markdown, a form sent to it and its lasting error link
  # answer 503 with Retry-After and ask to be opened again, and an agent
  # reading it through the forum API or the get_thread tool is told busy and
  # how long to wait. Try again opens the address that was opened, or after a
  # form the post itself. A post that is not there is still missing, and any
  # other database error is a fault, never busy.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias PatchbayWeb.ErrorLinkController

  setup do
    site = Forum.register_site!("busy-post.example")

    post =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "The cart never changed",
          thread_kind: :help_needed,
          body_markdown: "Asked on the board."
        },
        authorize?: false
      )

    %{post: post}
  end

  test "a post the database is too busy to read asks to be opened again, wherever it is named",
       %{conn: conn, post: post} do
    [code | _rest] = Map.keys(ErrorLinkController.links())
    markdown = put_req_header(conn, "accept", "text/markdown")
    reply = %{"reply" => %{"note" => "It worked."}}

    forms = [
      "/posts/#{post.id}/replies",
      "/reports/#{post.id}/replies",
      "/threads/#{post.id}/replies"
    ]

    [page, as_markdown, error_link, api, tool | sent_replies] =
      while_the_connection_is_held(
        [
          fn -> get(conn, PostAddress.path(post) <> "?after=x") end,
          fn -> get(markdown, PostAddress.path(post)) end,
          fn -> get(conn, "/errors/#{code}") end,
          fn -> get(conn, "/forum/threads/#{post.id}") end,
          fn -> get_thread(conn, post.id) end
        ] ++ Enum.map(forms, fn form -> fn -> post(conn, form, reply) end end)
      )

    for answer <- [page, error_link | sent_replies] do
      assert html_response(answer, 503) =~ "Patchbay is too busy to open this page right now."
      assert get_resp_header(answer, "retry-after") == ["2"]
    end

    assert try_again(page) == PostAddress.path(post) <> "?after=x"
    assert try_again(error_link) == "/errors/#{code}"

    # A form's own address cannot be opened, so Try again opens the post.
    for sent_reply <- sent_replies do
      assert try_again(sent_reply) == "/posts/#{post.id}"
      opened = get(build_conn(), try_again(sent_reply))
      assert redirected_to(opened, 301) == PostAddress.path(post)
    end

    assert response(as_markdown, 503) =~ "# Patchbay is too busy to open this page right now."
    assert [content_type] = get_resp_header(as_markdown, "content-type")
    assert content_type =~ "text/markdown"
    assert get_resp_header(as_markdown, "retry-after") == ["2"]

    assert %{"error" => %{"code" => "busy", "retry_after_seconds" => 2}} =
             json_response(api, 503)

    assert get_resp_header(api, "retry-after") == ["2"]

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             json_response(tool, 200)

    assert %{"error" => %{"code" => "busy", "retry_after_seconds" => 2}} = Jason.decode!(text)
  end

  test "a post that is not there is still missing", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/posts/#{Ash.UUID.generate()}") end
  end

  test "a database fault on a post is not answered as busy", %{conn: conn, post: post} do
    Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

    assert_error_sent 500, fn -> get(conn, PostAddress.path(post)) end

    api = get(conn, "/forum/threads/#{post.id}")
    assert %{"error" => %{"code" => "unavailable"}} = json_response(api, 503)
    assert get_resp_header(api, "retry-after") == []

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             conn |> get_thread(post.id) |> json_response(200)

    assert %{"error" => %{"code" => "unavailable"}} = Jason.decode!(text)
  end

  defp get_thread(conn, id) do
    call = %{"name" => "get_thread", "arguments" => %{"thread_id" => id}}

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: call}))
  end

  defp try_again(answer) do
    answer
    |> html_response(503)
    |> LazyHTML.from_document()
    |> LazyHTML.query("a.pb-cta")
    |> LazyHTML.attribute("href")
    |> hd()
  end

  # Another process holds the test's one database connection while `requests`
  # run together, so every read they make waits in the queue until the sandbox
  # drops it, as when a crowd has every connection. One hold serves them all,
  # since the queue is only cleared every ten seconds.
  defp while_the_connection_is_held(requests) do
    test = self()

    {holder, held} =
      spawn_monitor(fn ->
        Patchbay.Repo.transaction(fn ->
          send(test, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    answers = requests |> Enum.map(&Task.async/1) |> Task.await_many(30_000)
    send(holder, :release)
    assert_receive {:DOWN, ^held, :process, ^holder, :normal}
    answers
  end
end
