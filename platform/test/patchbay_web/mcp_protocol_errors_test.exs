defmodule PatchbayWeb.MCPProtocolErrorsTest do
  @moduledoc """
  A POST to the two hosted MCP addresses is answered in JSON-RPC an agent can
  act on even when the site answers before or around the server: a message
  sent to the other host's address or with a slash at the end, an `Accept`
  header that takes no JSON, a body that is not JSON, and a failure inside a
  tool call. Each keeps its HTTP status, carries the request's id when its body
  was read and the refusal's code in `data`, and is named in the visit line by
  that code. At the open address none of them names patchbay.help or money.

  A failure is still raised, so the error tracker records it and the server
  logs it as before. The three reads an agent starts with answer at both
  addresses as an MCP client sends them.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias PatchbayWeb.SignedAgent
  alias PatchbayWeb.SiteEdition

  @request %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list", "params" => %{}}

  # What the open address never names (open_edition_test.exs).
  @not_open ~r/usdc|paid|payment|\btip|award|wallet|escrow|bount|credit|offer|price|\bfree\b|(?<!open\.)patchbay\.help/i

  @client_accept "application/json, text/event-stream"

  describe "a message to an address this host's tools are not at" do
    test "names this host's address, where the same message is answered" do
      for {edition, path} <- [
            {:main, "/chatgpt/mcp"},
            {:open, "/mcp"},
            {:main, "/mcp/"},
            {:main, "/chatgpt/mcp/"},
            {:open, "/chatgpt/mcp/"},
            {:open, "/mcp/"}
          ] do
        {status, body} = sent(edition, path, Jason.encode!(@request))
        answer = Jason.decode!(body)

        assert status == 404, "#{edition} #{path}"
        assert_error(answer, -32_000, "wrong_address")
        # A slash address is answered before its body is read.
        assert answer["id"] == if(String.ends_with?(path, "/"), do: nil, else: 7)

        [address] =
          Regex.run(~r{https?://[^\s]+/(?:chatgpt/)?mcp}, answer["error"]["data"]["hint"])

        assert URI.parse(address).host == URI.parse(SiteEdition.url(edition)).host

        {status, body} = sent_to(address, Jason.encode!(@request))
        assert status == 200
        assert %{"id" => 7, "result" => %{"tools" => [_ | _]}} = Jason.decode!(body)

        if edition == :open, do: assert_open(body)
      end
    end

    test "on patchbay.help, the ChatGPT address names both addresses" do
      {404, body} = sent(:main, "/chatgpt/mcp", Jason.encode!(@request))
      message = Jason.decode!(body)["error"]["message"]

      assert message =~ SiteEdition.url(:main) <> "/mcp"
      assert message =~ SiteEdition.url(:open) <> "/chatgpt/mcp"
    end

    test "on the open address, names only its own" do
      for path <- ["/mcp", "/mcp/", "/chatgpt/mcp/"] do
        {404, body} = sent(:open, path, Jason.encode!(@request))

        assert_open(body)
        refute body =~ SiteEdition.url(:main)
      end
    end
  end

  test "an Accept header that takes no JSON is told so, and the call sent as clients send it is answered" do
    for {edition, path} <- [{:main, "/mcp"}, {:open, "/chatgpt/mcp"}],
        accept <- ["text/event-stream", "text/html"] do
      {status, body} = sent(edition, path, Jason.encode!(@request), accept: accept)
      answer = Jason.decode!(body)

      assert status == 406, "#{path} with #{accept}"
      assert answer["id"] == 7
      assert_error(answer, -32_000, "not_acceptable")
      if edition == :open, do: assert_open(body)

      {200, body} = sent(edition, path, Jason.encode!(@request), accept: @client_accept)
      assert %{"id" => 7, "result" => %{"tools" => [_ | _]}} = Jason.decode!(body)
    end
  end

  test "a body that is not JSON is a parse error, with no id" do
    for {edition, path} <- [{:main, "/mcp"}, {:open, "/chatgpt/mcp"}],
        body <- [~s({"jsonrpc": "2.0", "id": 7, "method": "tools/list"), "not json at all"] do
      {status, answer} = sent(edition, path, body)
      answer = Jason.decode!(answer)

      assert status == 400, "#{path}: #{body}"
      assert answer["id"] == nil
      assert_error(answer, -32_700, "parse_error")
      if edition == :open, do: assert_open(Jason.encode!(answer))
    end
  end

  # One failing request per test: each request is its own process in
  # production, and the error tracker reports one failure per process.
  for {edition, path} <- [{:main, "/mcp"}, {:open, "/chatgpt/mcp"}] do
    test "a failure inside a tool call at #{path} is Patchbay's -32603, and is still recorded",
         %{conn: conn} do
      Patchbay.Forum.register_site!("failing.example")
      Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN title TO hidden_away")

      search = %{
        "jsonrpc" => "2.0",
        "id" => "search-1",
        "method" => "tools/call",
        "params" => %{"name" => "search_threads", "arguments" => %{"origin" => "failing.example"}}
      }

      conn = for_edition(conn, unquote(edition))

      # Still raised, so the server logs it as before.
      {500, _headers, body} =
        assert_error_sent(500, fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> post(unquote(path), Jason.encode!(search))
        end)

      answer = Jason.decode!(body)

      assert answer["id"] == "search-1"
      assert_error(answer, -32_603, "internal_error")
      refute body =~ ~r/hidden_away|forum_reports|Postgrex|Ash\.|failing\.example/
      if unquote(edition) == :open, do: assert_open(body)

      assert [%{kind: "Elixir.Ash.Error.Unknown", occurrences: [occurrence]}] =
               ErrorTracker.Error |> Patchbay.Repo.all() |> Patchbay.Repo.preload(:occurrences)

      assert occurrence.context["request.path"] == unquote(path)
    end
  end

  test "each answer's visit line ends with its refusal's code" do
    # :info lines to survive the test logger level.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    lines =
      capture_log(fn ->
        sent(:main, "/chatgpt/mcp", Jason.encode!(@request))
        sent(:open, "/mcp", Jason.encode!(@request))
        sent(:main, "/mcp/", Jason.encode!(@request))
        sent(:main, "/mcp", Jason.encode!(@request), accept: "text/event-stream")
        sent(:open, "/chatgpt/mcp", "{not json")
      end)

    assert lines =~ "tool.call /chatgpt/mcp wrong_address"
    assert lines =~ "tool.call /mcp wrong_address"
    assert lines =~ "tool.call /mcp not_acceptable"
    assert lines =~ "tool.call /chatgpt/mcp parse_error"
    refute lines =~ ~r/tool\.call \S+ (not_found|status_\d+)/
  end

  test "the first three reads answer at both addresses as a connector sends them", %{conn: conn} do
    SignedAgent.stub_siwa()
    SignedAgent.stub_wallet_author()
    thread = ask!(conn, SignedAgent.pair!())

    reads = [
      {"get_patchbay_help", %{}},
      {"get_thread", %{"thread_id" => thread}},
      {"search_threads", %{"q" => "amend reservation"}}
    ]

    for {edition, path} <- [{:main, "/mcp"}, {:open, "/chatgpt/mcp"}],
        session? <- [false, true],
        {name, arguments} <- reads do
      headers =
        [accept: @client_accept, authorization: "Bearer a-token-from-another-service"] ++
          if session?, do: ["mcp-session-id": initialize!(conn, edition, path)], else: []

      call = %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      }

      {status, body} = sent(edition, path, Jason.encode!(call), headers)
      where = "#{name} at #{path}, session #{session?}"

      assert status == 200, "#{where}: #{body}"
      assert %{"id" => ^name, "result" => %{"isError" => false} = result} = Jason.decode!(body)

      case name do
        "get_patchbay_help" -> assert result["structuredContent"]["site"] == "Patchbay", where
        "get_thread" -> assert Jason.encode!(result["structuredContent"]) =~ thread, where
        "search_threads" -> assert Jason.encode!(result["structuredContent"]["results"]) =~ thread
      end
    end
  end

  property "any POST to either address, on either host, is answered in JSON-RPC" do
    check all(
            edition <- member_of([:main, :open]),
            path <- member_of(["/mcp", "/chatgpt/mcp", "/mcp/", "/chatgpt/mcp/"]),
            accept <-
              one_of([
                member_of([nil, @client_accept, "application/json", "text/event-stream"]),
                member_of(["text/html", "*/*", "text/markdown", "application/xml"]),
                string(:printable, max_length: 30)
              ]),
            content_type <-
              member_of([
                "application/json",
                "application/json; charset=utf-8",
                "text/plain",
                "application/x-www-form-urlencoded",
                "multipart/form-data"
              ]),
            body <- body(),
            max_runs: 200
          ) do
      headers = if accept, do: [accept: accept], else: []
      headers = [{:"content-type", content_type} | headers]

      {status, answer} = sent(edition, path, body, headers)
      where = "#{status} for #{edition} #{path} accept #{inspect(accept)}: #{inspect(body)}"

      assert status < 500, where

      if status == 202 do
        assert answer == "", where
      else
        assert {:ok, %{"jsonrpc" => "2.0"} = answer} = Jason.decode(answer), where
        assert Map.has_key?(answer, "id"), where
        assert Enum.count(["result", "error"], &Map.has_key?(answer, &1)) == 1, where

        if error = answer["error"] do
          assert is_integer(error["code"]) and is_binary(error["message"]), where
          if data = error["data"], do: assert(is_binary(data["code"]), where)
        end
      end
    end
  end

  # Mostly a request this server reads; sometimes JSON that is not one, a body
  # cut short, or anything at all.
  defp body do
    request =
      fixed_map(%{
        "jsonrpc" => constant("2.0"),
        "id" => one_of([integer(), string(:alphanumeric, max_length: 8)]),
        "method" => member_of(["initialize", "tools/list", "ping", "nothing/here"]),
        "params" => constant(%{})
      })

    frequency([
      {4, map(request, &Jason.encode!/1)},
      {1, map(json(), &Jason.encode!/1)},
      {2, map(request, &(&1 |> Jason.encode!() |> String.slice(0..-3//1)))},
      {1, string(:printable, max_length: 40)},
      {1, binary(max_length: 40)}
    ])
  end

  defp json do
    leaf = one_of([integer(), boolean(), constant(nil), string(:alphanumeric, max_length: 8)])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric, max_length: 6), child, max_length: 3)
      ])
    end)
  end

  defp assert_error(answer, code, data_code) do
    assert answer["jsonrpc"] == "2.0"
    assert Map.has_key?(answer, "id")
    refute Map.has_key?(answer, "result")
    assert %{"code" => ^code, "message" => message, "data" => data} = answer["error"]
    assert is_binary(message)
    assert %{"code" => ^data_code, "message" => ^message, "hint" => hint} = data
    assert is_binary(hint)
  end

  defp assert_open(body), do: assert(Regex.scan(@not_open, body) == [], body)

  defp sent(edition, path, body, headers \\ []),
    do: sent_to(SiteEdition.url(edition) <> path, body, headers)

  # What the client was sent, whether or not the request raised: Phoenix sends
  # an error's answer, then raises the error again for the test
  # (`Phoenix.ConnTest.assert_error_sent/2`).
  defp sent_to(address, body, headers \\ []) do
    request =
      ["content-type": "application/json"]
      |> Keyword.merge(headers)
      |> Enum.reduce(build_conn(:post, address, body), fn {name, value}, request ->
        put_req_header(request, Atom.to_string(name), value)
      end)

    try do
      PatchbayWeb.Endpoint.call(request, PatchbayWeb.Endpoint.init([]))
    rescue
      _raised_after_sending -> :sent
    end

    {status, _headers, answer} = Plug.Test.sent_resp(request)
    {status, answer}
  end

  defp for_edition(conn, :main), do: conn
  defp for_edition(conn, :open), do: on_open(conn)

  defp initialize!(conn, edition, path) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
    }

    request =
      conn
      |> for_edition(edition)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @client_accept)
      |> post(path, Jason.encode!(initialize))

    [session] = get_resp_header(request, "mcp-session-id")
    session
  end

  defp ask!(conn, agent) do
    question = %{
      "site" => "quiet.example.net",
      "title" => "Can this site amend a reservation?",
      "body_markdown" => "I found create_reservation but nothing to amend a reservation with.",
      "client_request_id" => Ecto.UUID.generate()
    }

    %{"result" => %{"structuredContent" => %{"thread_id" => thread}}} =
      conn
      |> SignedAgent.sign(agent)
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "ask_question", "arguments" => question}
        })
      )
      |> json_response(200)

    thread
  end
end
