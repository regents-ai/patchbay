defmodule PatchbayWeb.Forum.PostBusyTest do
  # A post the database is too busy to read is not called missing: its page,
  # a form sent to it and its lasting error link answer 503 with Retry-After
  # and ask to be opened again. A post that is not there is still missing, and
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

  test "a post the database is too busy to read asks to be opened again",
       %{conn: conn, post: post} do
    conn = while_the_connection_is_held(fn -> get(conn, PostAddress.path(post)) end)

    assert html_response(conn, 503) =~ "Patchbay is too busy to open this page right now."
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "a post the database is too busy to read answers the same as Markdown",
       %{conn: conn, post: post} do
    conn = put_req_header(conn, "accept", "text/markdown")
    conn = while_the_connection_is_held(fn -> get(conn, PostAddress.path(post)) end)

    assert response(conn, 503) =~ "# Patchbay is too busy to open this page right now."
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/markdown"
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "a reply sent to a post the database is too busy to read answers the same",
       %{conn: conn, post: post} do
    conn =
      while_the_connection_is_held(fn ->
        post(conn, "/posts/#{post.id}/replies", %{"reply" => %{"note" => "It worked."}})
      end)

    assert html_response(conn, 503) =~ "Patchbay is too busy to open this page right now."
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "an error link the database is too busy to follow answers the same", %{conn: conn} do
    [code | _rest] = Map.keys(ErrorLinkController.links())
    conn = while_the_connection_is_held(fn -> get(conn, "/errors/#{code}") end)

    assert html_response(conn, 503) =~ "Patchbay is too busy to open this page right now."
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "a post that is not there is still missing", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/posts/#{Ash.UUID.generate()}") end
  end

  test "a database fault on a post is not answered as busy", %{conn: conn, post: post} do
    Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

    assert_error_sent 500, fn -> get(conn, PostAddress.path(post)) end
  end

  # Another process holds the test's one database connection while `request`
  # runs, so every read the page makes waits and is dropped from the queue, as
  # when a crowd has every connection.
  defp while_the_connection_is_held(request) do
    test = self()

    {holder, held} =
      spawn_monitor(fn ->
        Patchbay.Repo.transaction(fn ->
          send(test, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    answer = request.()
    send(holder, :release)
    assert_receive {:DOWN, ^held, :process, ^holder, :normal}
    answer
  end
end
