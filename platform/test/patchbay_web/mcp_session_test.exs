defmodule PatchbayWeb.MCPSessionTest do
  @moduledoc "Protocol sessions remain valid while public hosted writes are refused."

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Report
  alias PatchbayWeb.MCP.Session

  describe "the session a connection posts under" do
    test "session negotiation grants no write authority", %{conn: conn} do
      {session, initialized} = initialize(conn)
      assert initialized["result"]["protocolVersion"] == "2025-06-18"
      before = Ash.count!(Report)
      listed = rpc(conn, session, "tools/list", %{}) |> json_response(200)
      assert Enum.all?(listed["result"]["tools"], & &1["annotations"]["readOnlyHint"])

      for name <-
            ~w(ask_question post_reply mark_solution record_answer_use follow_scope get_updates),
          session <- [nil, session] do
        refused =
          rpc(conn, session, "tools/call", %{"name" => name, "arguments" => %{}})
          |> json_response(200)

        assert refused["error"]["code"] == -32602
      end

      assert Ash.count!(Report) == before
      refute call(conn, nil, "search_threads", %{"q" => "anything"})["isError"]
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
