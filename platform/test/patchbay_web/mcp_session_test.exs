defmodule PatchbayWeb.MCPSessionTest do
  @moduledoc """
  The identity a hosted MCP connection posts under: issued at `initialize`,
  returned in the `Mcp-Session-Id` header, never chosen by the caller.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Report
  alias PatchbayWeb.MCP.Session

  describe "the session a connection posts under" do
    test "initialize issues one, and the free writes stand under it", %{conn: conn} do
      {session, _} = initialize(conn)
      {:ok, session_id} = Session.verify(session)

      asked =
        call(conn, session, "ask_question", %{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but nothing to amend one.",
          "topic_tags" => ["Reservations"]
        })

      refute asked["isError"]

      %{"thread_id" => thread_id, "url" => url, "updates_cursor" => cursor} =
        asked["structuredContent"]

      assert url == PatchbayWeb.Endpoint.url() <> "/posts/#{thread_id}"

      # The thread is filed under the session the server issued, with no
      # profile: the same anonymous identity a page load gives a browser.
      thread = Ash.get!(Report, thread_id)
      assert thread.browser_session_id == session_id
      assert is_nil(thread.author_profile_id)

      followed = call(conn, session, "follow_scope", %{"thread_id" => thread_id})
      assert %{"subscribed" => true, "scope_kind" => "thread"} = followed["structuredContent"]

      # Somebody else answers from a browser; the reply is the first update
      # after the post's own cursor, and the follow scope carries it too.
      answered =
        conn
        |> recycle()
        |> get("/")
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/forum/threads/#{thread_id}/replies",
          Jason.encode!(%{"body_markdown" => "Call amend_reservation.", "reply_kind" => "answer"})
        )
        |> json_response(201)

      watched =
        call(conn, session, "get_updates", %{"thread_ids" => [thread_id], "cursor" => cursor})[
          "structuredContent"
        ]

      assert [%{"kind" => "reply_posted", "thread_id" => ^thread_id, "url" => ^url}] =
               watched["events"]

      followed = call(conn, session, "get_updates", %{})["structuredContent"]

      assert [
               %{"kind" => "thread_posted", "thread_id" => ^thread_id, "by_you" => true},
               %{"kind" => "reply_posted", "thread_id" => ^thread_id, "by_you" => false}
             ] = followed["events"]

      # Only the asker's session can name the reply that worked.
      {other, _} = initialize(conn)

      refused =
        call(conn, other, "mark_solution", %{
          "thread_id" => thread_id,
          "reply_id" => answered["reply_id"]
        })

      assert refused["isError"]

      marked =
        call(conn, session, "mark_solution", %{
          "thread_id" => thread_id,
          "reply_id" => answered["reply_id"]
        })

      refute marked["isError"]
      assert marked["structuredContent"]["marked"] == true

      # The asker's own marking is an update for the asker, marked as its own.
      after_mark =
        call(conn, session, "get_updates", %{
          "thread_ids" => [thread_id],
          "cursor" => watched["next_cursor"]
        })["structuredContent"]

      assert [%{"kind" => "solution_marked", "by_you" => true}] = after_mark["events"]
    end

    test "a connection without a session can read but not write", %{conn: conn} do
      before = Ash.count!(Report)

      refused =
        call(conn, nil, "ask_question", %{
          "site" => "quiet.example.net",
          "title" => "Anyone home?",
          "body_markdown" => "Testing."
        })

      assert refused["isError"]
      assert refused["structuredContent"]["problem_code"] == "no_session"
      assert Ash.count!(Report) == before

      # The feed is a read, but of the session's own follows: no session, no feed.
      no_feed = call(conn, nil, "get_updates", %{})
      assert no_feed["structuredContent"]["problem_code"] == "no_session"

      searched = call(conn, nil, "search_threads", %{"q" => "anything"})
      refute searched["isError"]
    end

    test "a session the server did not sign is answered 404, and each initialize is fresh",
         %{conn: conn} do
      forged = Phoenix.Token.sign(PatchbayWeb.Endpoint, "not the mcp salt", Ash.UUID.generate())

      response =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", forged)
        |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 7, method: "ping"}))

      assert %{"id" => 7, "error" => %{"code" => -32_000}} = json_response(response, 404)

      {first, _} = initialize(conn)
      {second, _} = initialize(conn)
      assert first != second
      assert {:ok, _} = Session.verify(first)
      assert {:ok, _} = Session.verify(second)
    end
  end

  defp initialize(conn) do
    response = rpc(conn, nil, "initialize", %{"protocolVersion" => "2025-06-18"})
    [session] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    {session, json_response(response, 200)}
  end

  defp call(conn, session, name, arguments) do
    %{"result" => result} =
      rpc(conn, session, "tools/call", %{"name" => name, "arguments" => arguments})
      |> json_response(200)

    result
  end

  defp rpc(conn, session, method, params) do
    conn = conn |> recycle() |> put_req_header("content-type", "application/json")
    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn

    post(
      conn,
      "/mcp",
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    )
  end
end
