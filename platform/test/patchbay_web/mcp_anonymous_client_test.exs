defmodule PatchbayWeb.MCPAnonymousClientTest do
  @moduledoc """
  A client that connects to a hosted address with nothing but the address, as
  an agent host or ChatGPT does: `initialize`, `tools/list`, then `tools/call`
  with `{}`.

  - Every tool an address lists answers that call as a tool result, never as
    a JSON-RPC error, which a client shows only as a failed call (in ChatGPT,
    `upstream_error` / `INVALID_ARGUMENT`). An answer fits the `outputSchema`
    the same list gave, and its text is the same JSON. The site directory
    answers its first page.
  - `get_webmcp_guide` answers the guide's Markdown as /webmcp serves it,
    never the help.
  - A signed tool tells an unsigned caller how to sign at `/mcp`
    (`agent_auth_required`), the code the help names, and runs once a paired
    agent signs the same call, as `regents mcp` signs it.
  """

  # It switches ChatGPT identities on for the whole site in one test.
  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    SignedAgent.stub_wallet_author()
    :ok
  end

  test "every tool /mcp lists answers an anonymous call with a result its client accepts",
       %{conn: conn} do
    assert "read_site_directory" in accepted_everywhere(conn, "/mcp")
  end

  test "every tool the ChatGPT address lists answers an anonymous call with a result its client accepts",
       %{conn: conn} do
    assert "read_site_directory" in accepted_everywhere(conn, "/chatgpt/mcp")

    identities_on()
    answered = accepted_everywhere(conn, "/chatgpt/mcp")

    assert "read_site_directory" in answered
    assert length(tools(conn, "/chatgpt/mcp", nil)) == 12
  end

  test "the WebMCP guide answers its Markdown, as /webmcp serves it, not the help",
       %{conn: conn} do
    session = initialize(conn, "/mcp")
    guide = answer(conn, "/mcp", session, "get_webmcp_guide")
    help = answer(conn, "/mcp", session, "get_patchbay_help")

    assert %{"format" => "markdown", "guide" => markdown} = guide
    assert map_size(guide) == 2
    refute guide == help

    page = conn |> recycle() |> put_req_header("accept", "text/markdown") |> get("/webmcp")

    assert [type] = get_resp_header(page, "content-type")
    assert type =~ "text/markdown"
    assert page.resp_body == markdown
  end

  test "a signed tool tells an unsigned caller how to sign here, and runs once signed",
       %{conn: conn} do
    agent = SignedAgent.pair!()
    session = initialize(conn, "/mcp")
    help = answer(conn, "/mcp", session, "get_patchbay_help")

    calls = [
      {"ask_question",
       %{
         "site" => "quiet.example.net",
         "title" => "Can this site amend a reservation?",
         "body_markdown" => "I found create_reservation but nothing to amend one.",
         "client_request_id" => Ecto.UUID.generate()
       }},
      {"get_request_status", %{"client_request_id" => Ecto.UUID.generate()}},
      {"get_updates", %{}}
    ]

    for {name, arguments} <- calls do
      unsigned = result(call(conn, "/mcp", session, name, arguments))

      assert unsigned["isError"], name
      assert %{"code" => code, "hint" => hint} = refusal(unsigned)
      assert code == "agent_auth_required", "#{name}: #{code}"
      assert help["your_identity"] =~ code
      assert hint =~ "regents mcp"

      signed = conn |> call("/mcp", session, name, arguments, agent) |> result()

      admitted? =
        not signed["isError"] or
          refusal(signed)["code"] not in ["agent_auth_required", "http_headers_missing"]

      assert admitted?, "#{name} was refused a signed call: #{inspect(signed)}"
    end
  end

  # Calls every tool `path` lists with `{}`, as a client that has only the
  # list does, and returns the names that answered rather than refused.
  defp accepted_everywhere(conn, path) do
    session = initialize(conn, path)

    for tool <- tools(conn, path, session), reduce: [] do
      answered ->
        answer = call(conn, path, session, tool["name"], %{}) |> json_response(200)

        refute Map.has_key?(answer, "error"),
               "#{tool["name"]} answered with a JSON-RPC error: #{inspect(answer["error"])}"

        accepted(tool, answer["result"], answered)
    end
  end

  defp accepted(tool, %{"isError" => true} = result, answered) do
    refute Map.has_key?(result, "structuredContent"), tool["name"]
    answered
  end

  defp accepted(
         tool,
         %{"structuredContent" => answer, "content" => [%{"text" => text}]},
         answered
       ) do
    assert {:ok, _} = JSV.validate(answer, JSV.build!(tool["outputSchema"])),
           "#{tool["name"]} answered outside its outputSchema"

    assert Jason.decode!(text) == answer, "#{tool["name"]}'s text is not its answer"
    [tool["name"] | answered]
  end

  defp identities_on do
    put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "http://127.0.0.1:1", key: String.duplicate("k", 32)]
    )

    put_env(
      :patchbay,
      Patchbay.OAuth,
      Keyword.merge(Application.fetch_env!(:patchbay, Patchbay.OAuth),
        enabled?: true,
        additional_scopes: %{
          RegentMCPAgents.identity_scope() => "connect ChatGPT",
          RegentMCPAgents.posting_scope() => "post free questions and replies"
        }
      )
    )

    put_env(:regent_agents, :hosted_pairing, [:chatgpt])
  end

  defp put_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> Application.put_env(app, key, old) end)
  end

  defp initialize(conn, path) do
    initialized =
      rpc(conn, path, nil, "initialize", %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "anonymous", "version" => "1"}
      })

    assert [session] = get_resp_header(initialized, "mcp-session-id")
    session
  end

  defp tools(conn, path, session),
    do:
      rpc(conn, path, session, "tools/list", %{})
      |> json_response(200)
      |> get_in(["result", "tools"])

  defp answer(conn, path, session, name),
    do: call(conn, path, session, name, %{}) |> result() |> Map.fetch!("structuredContent")

  # `agent`, when named, signs the call as `regents mcp` would.
  defp call(conn, path, session, name, arguments, agent \\ nil) do
    params = %{"name" => name, "arguments" => arguments}
    rpc(conn, path, session, "tools/call", params, agent)
  end

  defp result(answer), do: answer |> json_response(200) |> Map.fetch!("result")

  defp refusal(%{"content" => [%{"text" => text}]}), do: Jason.decode!(text)["error"]

  defp rpc(conn, path, session, method, params, agent \\ nil) do
    conn = conn |> recycle() |> put_req_header("content-type", "application/json")
    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    conn = if agent, do: SignedAgent.sign(conn, agent), else: conn
    conn = if String.starts_with?(path, "/chatgpt/"), do: on_open(conn), else: conn

    post(conn, path, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
