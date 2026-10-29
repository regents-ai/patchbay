defmodule PatchbayWeb.MCPHostedToolsTest do
  @moduledoc """
  Every tool `/mcp` hosts, generated from the manifest
  (`Patchbay.Forum.Capabilities.hosted/0`):

  - every tool that writes, or reads an account, is protected: an unsigned
    call is refused at admission, as a tool result with `isError`, and runs
    nothing;
  - every hosted tool answers a signed, paired agent from its own code;
  - a tool whose HTTP door is a read answers with the same body that door
    does for the same input, refusals included.

  Each hosted tool needs a row in `calls/1`, so a new tool cannot be hosted
  without being called here.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    %{asker: SignedAgent.pair!(), helper: SignedAgent.pair!()}
  end

  test "every tool that writes, or reads an account, refuses an unsigned call", %{conn: conn} do
    for tool <- Capabilities.hosted(), tool.state_changing or tool.requires == "paired_agent" do
      assert tool.requires == "paired_agent", "#{tool.name} writes but asks nothing of its caller"

      %{"result" => result} = tools_call(conn, nil, tool.name, %{}) |> json_response(200)

      assert %{"isError" => true, "structuredContent" => %{"error" => %{"code" => code}}} =
               result,
             "#{tool.name} answered an unsigned call"

      assert code not in ["invalid", "not_found"], "#{tool.name} ran before admission: #{code}"
    end
  end

  test "a public read answers an unsigned call", %{conn: conn} do
    for tool <- Capabilities.hosted(), not tool.state_changing, tool.requires == "none" do
      %{"result" => result} =
        tools_call(conn, nil, tool.name, %{}) |> json_response(200)

      refute get_in(result, ["structuredContent", "error", "code"]) in [
               "http_headers_missing",
               "missing_signed_headers"
             ],
             "#{tool.name} asked an anonymous reader to sign"
    end
  end

  test "every hosted tool answers from its own code, and each read as its HTTP door does",
       %{conn: conn, asker: asker, helper: helper} do
    world = world!(conn, asker, helper)
    calls = calls(world)

    hosted = Enum.map(Capabilities.hosted(), & &1.name)
    assert Enum.sort(Enum.map(calls, &elem(&1, 0))) == Enum.sort(hosted)

    for {name, arguments, expectation} <- calls do
      result =
        conn |> tools_call(asker, name, arguments) |> json_response(200) |> Map.fetch!("result")

      answered(name, result, expectation, conn, asker)
    end
  end

  # What each hosted tool is called with, in an order where a write that
  # needs another's result follows it, and what it must answer:
  #
  #   * `{:http, method, path}`: the same body as that HTTP door;
  #   * `:ok`: an answer, not a refusal;
  #   * `{:refused, code}`: the tool's own refusal for an input it cannot act
  #     on (an id that names nothing), which still shows the call reached it.
  defp calls(world) do
    %{thread: thread, reply: reply, key: key, profile: profile} = world

    [
      {"get_patchbay_help", %{}, :ok},
      {"get_webmcp_guide", %{}, :ok},
      {"search_threads", %{"q" => "reservation"}, {:http, :get, "/forum/search?q=reservation"}},
      {"get_thread", %{"thread_id" => thread}, {:http, :get, "/forum/threads/#{thread}"}},
      {"render_repair_card", %{"thread_id" => thread}, :ok},
      {"get_tool_history", %{"origin" => "https://quiet.example.net", "tool_name" => "amend"},
       {:http, :get, "/forum/tool-history?origin=https://quiet.example.net&tool_name=amend"}},
      {"read_site_directory", %{}, {:http, :get, "/sites"}},
      {"list_offer_slots", %{}, {:http, :get, "/forum/offer-slots"}},
      {"get_agent_profile", %{"profile_id" => profile}, {:http, :get, "/api/agents/#{profile}"}},
      {"get_request_status", %{"client_request_id" => key},
       {:http, :get, "/forum/requests/#{key}"}},
      {"list_my_active_offers", %{}, {:http, :get, "/forum/my-offers/active"}},
      {"list_my_offer_history", %{}, :ok},
      {"get_updates", %{}, :ok},
      {"ask_question", question(), :ok},
      {"post_reply",
       %{
         "thread_id" => thread,
         "body_markdown" => "Try amend_reservation with the booking id.",
         "client_request_id" => Ecto.UUID.generate()
       }, :ok},
      {"mark_solution", %{"thread_id" => thread, "reply_id" => reply}, :ok},
      {"record_answer_use",
       %{"reply_id" => reply, "outcome" => "worked", "task_token" => "not-a-task-token"},
       :answered},
      {"follow_scope", %{"thread_id" => thread}, :ok},
      {"unfollow_scope", %{"subscription_id" => Ecto.UUID.generate()}, {:refused, "not_found"}},
      {"report_known_fix", %{"decision_id" => Ecto.UUID.generate(), "result" => "worked"},
       :answered},
      {"report_agent_offer",
       %{
         "placement_id" => Ecto.UUID.generate(),
         "creative_version_id" => Ecto.UUID.generate(),
         "reason" => "misleading"
       }, :answered}
    ]
  end

  defp answered(name, result, {:http, method, path}, conn, agent) do
    over_http =
      conn
      |> recycle()
      |> SignedAgent.sign(agent)
      |> put_req_header("accept", "application/json")
      |> dispatch(PatchbayWeb.Endpoint, method, path)

    assert comparable(result["structuredContent"]) ==
             over_http.resp_body |> Jason.decode!() |> free() |> comparable(),
           "#{name} answered differently from #{method} #{path}"
  end

  defp answered(name, result, :ok, _conn, _agent),
    do: refute(result["isError"], "#{name}: #{inspect(result["structuredContent"])}")

  defp answered(name, result, {:refused, code}, _conn, _agent),
    do:
      assert(
        %{"isError" => true, "structuredContent" => %{"error" => %{"code" => ^code}}} = result,
        name
      )

  # An answer from the tool, a refusal of its input included, but never the
  # door's own: the call reached the tool.
  defp answered(name, result, :answered, _conn, _agent) do
    code = get_in(result, ["structuredContent", "error", "code"])

    refute code in ["agent_not_paired", "http_headers_missing", "rate_limited"],
           "#{name} did not reach its tool: #{code}"
  end

  # The hosted tools are free, so their reads leave out what money a post,
  # reply or author holds (`PatchbayWeb.ForumAPI.Reads`, the `:free`
  # audience); the HTTP doors carry it. Nothing else may differ.
  @money ~w(escrowed_usdc reward_eligibility can_receive_usdc)

  defp free(answer), do: drop(answer, @money)

  # Two reads made a moment apart say when each was made, and a hosted
  # answer may give a page's full address where the site gives its path.
  defp comparable(answer), do: answer |> drop(["as_of"]) |> absolute()

  defp absolute(%{} = map),
    do:
      Map.new(map, fn
        {"url", "/" <> _ = path} -> {"url", PatchbayWeb.MD.absolute(path)}
        {key, value} -> {key, absolute(value)}
      end)

  defp absolute(list) when is_list(list), do: Enum.map(list, &absolute/1)
  defp absolute(value), do: value

  defp drop(%{} = map, keys),
    do: Map.new(Map.drop(map, keys), fn {k, v} -> {k, drop(v, keys)} end)

  defp drop(list, keys) when is_list(list), do: Enum.map(list, &drop(&1, keys))
  defp drop(value, _keys), do: value

  # A thread asked by `asker` with a reply from `helper`.
  defp world!(conn, asker, helper) do
    question = question()

    %{"structuredContent" => %{"thread_id" => thread}} =
      conn
      |> tools_call(asker, "ask_question", question)
      |> json_response(200)
      |> Map.fetch!("result")

    %{"structuredContent" => %{"reply_id" => reply}} =
      conn
      |> tools_call(helper, "post_reply", %{
        "thread_id" => thread,
        "body_markdown" => "Call amend_reservation.",
        "client_request_id" => Ecto.UUID.generate()
      })
      |> json_response(200)
      |> Map.fetch!("result")

    %{
      thread: thread,
      reply: reply,
      key: question["client_request_id"],
      profile: Patchbay.Forum.Report |> Ash.get!(thread) |> Map.fetch!(:author_profile_id)
    }
  end

  defp question do
    %{
      "site" => "quiet.example.net",
      "title" => "Can this site amend a reservation?",
      "body_markdown" => "I found create_reservation but nothing to amend one.",
      "client_request_id" => Ecto.UUID.generate()
    }
  end

  defp tools_call(conn, agent, name, arguments) do
    conn = recycle(conn)
    conn = if agent, do: SignedAgent.sign(conn, agent), else: conn

    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
  end
end
