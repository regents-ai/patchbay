defmodule PatchbayWeb.VisitLinesTest do
  @moduledoc """
  The visit lines Patchbay's own doors write (`PatchbayWeb.VisitLog`): a hosted
  MCP call by its address and tool, a page's tool reading a page, and an issue
  page read, each with how it ended and never with the caller's own words.
  """

  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    # :info lines to survive the test logger level.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "a hosted MCP call is named by its address and tool, and a plugin's by its own", %{
    conn: conn
  } do
    lines =
      capture_log(fn ->
        rpc(conn, "/mcp", "tools/call", %{"name" => "get_patchbay_help", "arguments" => %{}})
        rpc(on_open(conn), "/chatgpt/mcp", "tools/list", %{})
      end)

    assert lines =~ "tool.call /mcp:get_patchbay_help ok"
    assert lines =~ "tool.call /chatgpt/mcp:tools/list ok"
  end

  test "an MCP call to a tool or method the server lacks never writes the caller's words", %{
    conn: conn
  } do
    lines =
      capture_log(fn ->
        rpc(conn, "/mcp", "tools/call", %{"name" => "drop_every_table", "arguments" => %{}})
        rpc(conn, "/mcp", "wipe/everything", %{})
      end)

    assert lines =~ "tool.call /mcp:tools/call invalid_params"
    assert lines =~ "tool.call /mcp:other method_not_found"
    refute lines =~ "drop_every_table"
    refute lines =~ "wipe"
  end

  test "a page's tool reading a page is a tool call by the tool's name", %{conn: conn} do
    lines =
      capture_log(fn ->
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-regent-client", "webmcp/read_site_directory")
        |> get("/sites")
      end)

    assert lines =~ "tool.call read_site_directory ok"
  end

  test "an issue page read is a request line by its route", %{conn: conn} do
    [incident | _] = Patchbay.Incidents.all()

    lines = capture_log(fn -> get(conn, "/incidents/#{incident.name}") end)

    assert lines =~ "request /incidents/#{incident.name} ok"
  end

  defp rpc(conn, path, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
