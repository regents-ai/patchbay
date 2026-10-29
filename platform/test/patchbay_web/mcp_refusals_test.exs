defmodule PatchbayWeb.MCPRefusalsTest do
  @moduledoc """
  Every refusal at the hosted MCP addresses is a JSON-RPC answer to the
  request it refuses, with that request's id, so an MCP client shows the
  model what to do instead of a failed connection: a refused tool call is a
  tool result with `isError` and the `{code, message, hint}` every door
  answers with. A rate limit says how many seconds to wait, never pairing.
  The connection's own rules (expiry, protocol version, the server's
  version) answer as the protocol asks.
  """

  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.SignedAgent

  @question %{
    "name" => "ask_question",
    "arguments" => %{
      "site" => "quiet.example.net",
      "title" => "Can this site amend a reservation?",
      "body_markdown" => "I found create_reservation but nothing to amend one."
    }
  }

  setup do
    SignedAgent.stub_siwa()
    :ok
  end

  describe "admission refusals are tool errors with the request's id" do
    test "an unsigned write", %{conn: conn} do
      error = refused_tool(post_rpc(conn, "/mcp", "unsigned-1", "tools/call", @question))

      assert %{"code" => code, "message" => message, "hint" => hint} = error
      assert code != "rate_limited"
      assert message != "" and hint =~ "sign"
    end

    test "an unsigned events method is a JSON-RPC error carrying the same refusal", %{conn: conn} do
      answer =
        conn
        |> post_rpc("/mcp", 41, "events/subscribe", %{"name" => "reply_created"})
        |> json_response(200)

      assert %{"id" => 41, "error" => %{"code" => -32_000, "data" => %{"hint" => _}}} = answer
    end

    test "an agent that is not paired", %{conn: conn} do
      stranger = %{wallet: "0x" <> String.duplicate("ab", 20)}

      error =
        conn
        |> SignedAgent.sign(stranger)
        |> post_rpc("/mcp", 7, "tools/call", @question)
        |> refused_tool(7)

      assert error["code"] == "agent_not_paired"
      assert error["hint"] =~ "Pair New Agent"
    end

    test "the sign-in service down", %{conn: conn} do
      agent = SignedAgent.pair!()
      Req.Test.stub(RegentAgents.Broker, &Req.Test.transport_error(&1, :econnrefused))

      error =
        conn
        |> SignedAgent.sign(agent)
        |> post_rpc("/mcp", 8, "tools/call", @question)
        |> refused_tool(8)

      assert error["code"] == "siwa_request_failed"
      assert error["hint"] == "Try again in a moment."
    end
  end

  describe "a rate limit reads as a wait, never as pairing" do
    test "past the signed share", %{conn: conn} do
      agent = SignedAgent.pair!()
      limited(:signed_per_minute)
      updates = %{"name" => "get_updates", "arguments" => %{}}
      conn |> SignedAgent.sign(agent) |> post_rpc("/mcp", 0, "tools/call", updates)

      conn =
        conn
        |> recycle()
        |> SignedAgent.sign(agent)
        |> post_rpc("/mcp", 9, "tools/call", @question)

      error = refused_tool(conn, 9)

      assert_wait(conn, error, "signed")
    end

    test "past the reads share, at both addresses", %{conn: conn} do
      limited(:reads_per_minute)
      conn |> post_rpc("/mcp", 0, "ping", %{})

      for path <- ["/mcp", "/chatgpt/mcp"] do
        call = %{"name" => "search_threads", "arguments" => %{"q" => "reservation"}}
        conn = conn |> recycle() |> post_rpc(path, "r-1", "tools/call", call)
        assert_wait(conn, refused_tool(conn, "r-1"), "reads")

        listed = conn |> recycle() |> post_rpc(path, 12, "tools/list", %{})
        assert %{"id" => 12, "error" => %{"data" => error}} = json_response(listed, 200)
        assert_wait(listed, error, "reads")
      end
    end
  end

  test "arguments that break a tool's schema are a tool error the model can correct",
       %{conn: conn} do
    call = %{"name" => "search_threads", "arguments" => %{"q" => 42}}
    error = refused_tool(post_rpc(conn, "/mcp", 3, "tools/call", call), 3)

    assert %{"code" => "invalid", "details" => [detail]} = error
    assert detail =~ "q"
  end

  test "an expired session answers 404, which starts a new one, and says it expired",
       %{conn: conn} do
    long_ago = System.os_time(:second) - 91 * 24 * 60 * 60

    expired =
      Phoenix.Token.sign(PatchbayWeb.Endpoint, "mcp session", Ash.UUID.generate(),
        signed_at: long_ago
      )

    answer =
      conn
      |> put_req_header("mcp-session-id", expired)
      |> post_rpc("/mcp", 5, "ping", %{})
      |> json_response(404)

    assert %{"id" => 5, "error" => %{"data" => %{"code" => "connection_expired"}}} = answer
  end

  test "a protocol version Patchbay does not speak is refused with 400", %{conn: conn} do
    answer =
      conn
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> post_rpc("/mcp", 6, "tools/list", %{})
      |> json_response(400)

    assert %{"id" => 6, "error" => %{"message" => message}} = answer
    assert message =~ "2025-11-25"

    for version <- ["2025-11-25", "2026-07-28"] do
      assert conn
             |> recycle()
             |> put_req_header("mcp-protocol-version", version)
             |> post_rpc("/mcp", 6, "tools/list", %{})
             |> json_response(200)
    end
  end

  test "a refused version stops the call, even for a ChatGPT identity tool", %{conn: conn} do
    config = Application.get_env(:regent_mcp_agents, :config, [])
    on_exit(fn -> Application.put_env(:regent_mcp_agents, :config, config) end)
    Application.put_env(:regent_mcp_agents, :config, Keyword.put(config, :enabled?, true))

    answer =
      conn
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> post_rpc("/chatgpt/mcp", 13, "tools/call", %{
        "name" => "register_identity",
        "arguments" => %{}
      })
      |> json_response(400)

    assert %{"id" => 13, "error" => %{"code" => -32_600}} = answer
  end

  test "a refused notification gets the refusal's HTTP status, since it asks for no answer",
       %{conn: conn} do
    body = Jason.encode!(%{jsonrpc: "2.0", method: "tools/call", params: @question})

    answer =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", body)

    assert answer.status == 401
    assert %{"id" => nil, "error" => %{"data" => %{"code" => _}}} = json_response(answer, 401)
  end

  test "serverInfo names the running build's commit", %{conn: conn} do
    build = Application.fetch_env!(:patchbay, :build)
    on_exit(fn -> Application.put_env(:patchbay, :build, build) end)
    Application.put_env(:patchbay, :build, %{build | commit: "2f7453adcb2b"})

    for path <- ["/mcp", "/chatgpt/mcp"] do
      answer =
        conn
        |> recycle()
        |> post_rpc(path, 1, "initialize", %{"protocolVersion" => "2025-11-25"})
        |> json_response(200)

      assert answer["result"]["serverInfo"]["version"] == "2f7453adcb2b"
    end
  end

  defp refused_tool(conn, id \\ "unsigned-1") do
    assert %{"jsonrpc" => "2.0", "id" => ^id, "result" => result} = json_response(conn, 200)
    assert %{"isError" => true, "structuredContent" => %{"error" => error}} = result
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == error["message"] <> " " <> error["hint"]
    error
  end

  # A share of one a minute: the test spends it, and its next call is past it.
  defp limited(share) do
    before = Application.fetch_env!(:patchbay, share)
    on_exit(fn -> Application.put_env(:patchbay, share, before) end)
    Application.put_env(:patchbay, share, 1)
  end

  defp assert_wait(conn, error, share) do
    assert %{"code" => "rate_limited", "retry_after_seconds" => seconds} = error
    assert is_integer(seconds) and seconds > 0
    assert error["message"] =~ "Wait #{seconds} second"
    refute error["message"] =~ ~r/pair/i
    refute error["hint"] =~ ~r/pair/i
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
    assert [policy] = get_resp_header(conn, "ratelimit-policy")
    assert policy =~ ~s("#{share}")
  end

  defp post_rpc(conn, path, id, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
  end
end
