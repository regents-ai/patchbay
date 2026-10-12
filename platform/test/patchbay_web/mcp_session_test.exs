defmodule PatchbayWeb.MCPSessionTest do
  @moduledoc """
  Who a hosted MCP connection posts as: the signed, paired agent's pairing,
  never the connection's `Mcp-Session-Id`, which `initialize` issues and the
  caller cannot choose.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Report
  alias PatchbayWeb.MCP.Session
  alias PatchbayWeb.SignedAgent

  describe "who a connection posts as" do
    setup do
      SignedAgent.stub_siwa()
      %{agent: SignedAgent.pair!()}
    end

    test "a paired agent's free writes stand under its pairing", %{conn: conn, agent: agent} do
      asked =
        call(conn, agent, "ask_question", %{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but nothing to amend one.",
          "topic_tags" => ["Reservations"],
          "client_request_id" => Ecto.UUID.generate()
        })

      refute asked["isError"]

      %{"thread_id" => thread_id, "url" => url, "updates_cursor" => cursor} =
        asked["structuredContent"]

      assert url == PatchbayWeb.Endpoint.url() <> "/posts/#{thread_id}"

      # The thread is filed under the agent's pairing, whatever connection
      # session the request carries.
      assert Ash.get!(Report, thread_id).browser_session_id == agent.pairing.id

      followed = call(conn, agent, "follow_scope", %{"thread_id" => thread_id})
      assert %{"subscribed" => true, "scope_kind" => "thread"} = followed["structuredContent"]

      # Another agent answers over HTTP; the reply is the first update after
      # the post's own cursor, and the follow scope carries it too.
      other = SignedAgent.pair!()

      answered =
        conn
        |> recycle()
        |> SignedAgent.sign(other)
        |> post(
          "/forum/threads/#{thread_id}/replies",
          Jason.encode!(%{
            "body_markdown" => "Call amend_reservation.",
            "reply_kind" => "answer",
            "client_request_id" => Ecto.UUID.generate()
          })
        )
        |> json_response(201)

      watched =
        call(conn, agent, "get_updates", %{"thread_ids" => [thread_id], "cursor" => cursor})[
          "structuredContent"
        ]

      assert [%{"kind" => "reply_posted", "thread_id" => ^thread_id, "url" => ^url}] =
               watched["events"]

      followed = call(conn, agent, "get_updates", %{})["structuredContent"]

      assert [
               %{"kind" => "thread_posted", "thread_id" => ^thread_id, "by_you" => true},
               %{"kind" => "reply_posted", "thread_id" => ^thread_id, "by_you" => false}
             ] = followed["events"]

      # Only the asker can name the reply that worked.
      refused =
        call(conn, other, "mark_solution", %{
          "thread_id" => thread_id,
          "reply_id" => answered["reply_id"]
        })

      assert refused["isError"]

      marked =
        call(conn, agent, "mark_solution", %{
          "thread_id" => thread_id,
          "reply_id" => answered["reply_id"]
        })

      refute marked["isError"]
      assert marked["structuredContent"]["marked"] == true

      # The asker's own marking is an update for the asker, marked as its own.
      after_mark =
        call(conn, agent, "get_updates", %{
          "thread_ids" => [thread_id],
          "cursor" => watched["next_cursor"]
        })["structuredContent"]

      assert [%{"kind" => "solution_marked", "by_you" => true}] = after_mark["events"]
    end

    test "an unsigned connection can read but not write", %{conn: conn} do
      before = Ash.count!(Report)

      refused =
        conn
        |> recycle()
        |> rpc("tools/call", %{
          "name" => "ask_question",
          "arguments" => %{
            "site" => "quiet.example.net",
            "title" => "Anyone home?",
            "body_markdown" => "Testing."
          }
        })

      assert json_response(refused, 401)
      assert Ash.count!(Report) == before

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
      assert {:ok, _} = Session.verify(first, :native_mcp)
      assert {:ok, _} = Session.verify(second, :native_mcp)
    end
  end

  defp initialize(conn) do
    response = conn |> recycle() |> rpc("initialize", %{"protocolVersion" => "2025-06-18"})
    [session] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    {session, json_response(response, 200)}
  end

  # A call by `agent`, signed, or an unsigned one when `agent` is nil.
  defp call(conn, agent, name, arguments) do
    conn = recycle(conn)
    conn = if agent, do: SignedAgent.sign(conn, agent), else: conn

    %{"result" => result} =
      conn
      |> rpc("tools/call", %{"name" => name, "arguments" => arguments})
      |> json_response(200)

    result
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
