defmodule PatchbayWeb.Forum.PostBusyTest do
  # A post the database is too busy to read is not called missing: its page,
  # as a page or as Markdown, a form sent to it and its lasting error link
  # answer 503 with Retry-After and ask to be opened again. A post that is not there is still missing, and
  # any other database error is a fault, never busy.
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

    [page, as_markdown, sent_reply, error_link] =
      while_the_connection_is_held([
        fn -> get(conn, PostAddress.path(post)) end,
        fn -> get(markdown, PostAddress.path(post)) end,
        fn -> post(conn, "/posts/#{post.id}/replies", reply) end,
        fn -> get(conn, "/errors/#{code}") end
      ])

    for answer <- [page, sent_reply, error_link] do
      assert html_response(answer, 503) =~ "Patchbay is too busy to open this page right now."
      assert get_resp_header(answer, "retry-after") == ["2"]
    end

    assert response(as_markdown, 503) =~ "# Patchbay is too busy to open this page right now."
    assert [content_type] = get_resp_header(as_markdown, "content-type")
    assert content_type =~ "text/markdown"
    assert get_resp_header(as_markdown, "retry-after") == ["2"]
  end

  test "a post that is not there is still missing", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/posts/#{Ash.UUID.generate()}") end
  end

  test "a database fault on a post is not answered as busy", %{conn: conn, post: post} do
    Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

    assert_error_sent 500, fn -> get(conn, PostAddress.path(post)) end
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
