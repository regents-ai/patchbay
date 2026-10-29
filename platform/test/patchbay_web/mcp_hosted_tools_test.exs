defmodule PatchbayWeb.MCPHostedToolsTest do
  @moduledoc """
  Every tool `/mcp` hosts, generated from the manifest
  (`Patchbay.Forum.Capabilities.hosted/0`):

  - every tool that writes, or reads an account, is protected: an unsigned
    call is refused at admission, as a tool result with `isError`, and runs
    nothing;
  - every hosted tool answers a signed, paired agent from its own code;
  - a tool answers with the same body its HTTP door does for the same
    input, and both answer or both refuse: every read, and each write whose
    second sending changes nothing (a like, a saved Offer under its request
    key, a refused report).

  Each hosted tool needs a row in `calls/1`, so a new tool cannot be hosted
  without being called here.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.SignedAgent

  # What admission answers a request with no signature headers.
  @unsigned Siwa.Contract.refusal(:missing_signed_headers) |> elem(1)

  setup do
    SignedAgent.stub_siwa()
    %{asker: SignedAgent.pair!(), helper: SignedAgent.pair!()}
  end

  test "every tool that writes, or reads an account, refuses an unsigned call", %{conn: conn} do
    for tool <- Capabilities.hosted(), tool.state_changing or tool.requires == "paired_agent" do
      assert tool.requires == "paired_agent", "#{tool.name} writes but asks nothing of its caller"

      %{"result" => result} = tools_call(conn, nil, tool.name, %{}) |> json_response(200)

      assert result["isError"], "#{tool.name} answered an unsigned call"
      code = code(result)
      assert code == @unsigned, "#{tool.name} was not refused at admission: #{code}"
    end
  end

  test "a public read answers an unsigned call", %{conn: conn} do
    for tool <- Capabilities.hosted(), not tool.state_changing, tool.requires == "none" do
      %{"result" => result} =
        tools_call(conn, nil, tool.name, %{}) |> json_response(200)

      refute result["isError"] and code(result) == @unsigned,
             "#{tool.name} asked an anonymous reader to sign"
    end
  end

  test "every hosted tool answers from its own code, and each read as its HTTP door does",
       %{conn: conn, asker: asker, helper: helper} do
    world = world!(conn, asker, helper)
    calls = calls(world)

    hosted = Enum.map(Capabilities.hosted(), & &1.name)
    assert calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == Enum.sort(hosted)

    for {name, arguments, expectation} <- calls do
      result =
        conn |> tools_call(asker, name, arguments) |> json_response(200) |> Map.fetch!("result")

      answered(name, result, expectation, conn, asker)
      shaped(name, result)
    end
  end

  # An answer has the shape its tool's outputSchema in tools/list promises,
  # so a client that checks it accepts it, and its text is the same answer as
  # JSON for a client that reads only text. A refusal carries no structured
  # content for a client to check against that schema: its text is the
  # refusal's JSON.
  defp shaped(name, %{"isError" => true} = result) do
    refute Map.has_key?(result, "structuredContent"), name
    assert %{"error" => %{"code" => _, "message" => _, "hint" => _}} = refusal(result)
  end

  defp shaped(name, %{"structuredContent" => answer, "content" => [%{"text" => text}]}) do
    schema = Map.fetch!(output_schemas(), name)

    assert {:ok, _} = JSV.validate(answer, JSV.build!(schema)),
           "#{name} answered outside its outputSchema: #{inspect(answer, limit: 8)}"

    assert Jason.decode!(text) == answer, "#{name}'s text is not its answer"
  end

  defp refusal(%{"content" => [%{"text" => text}]}), do: Jason.decode!(text)

  defp code(result), do: refusal(result)["error"]["code"]

  # The answer either way: the structured answer, or the refusal's JSON.
  defp body(%{"isError" => true} = result), do: refusal(result)
  defp body(result), do: result["structuredContent"]

  defp output_schemas do
    Map.new(PatchbayWeb.MCP.Tools.list(:native_mcp), &{&1.name, &1.outputSchema})
  end

  # What each hosted tool is called with, in an order where a write that
  # needs another's result follows it, and what it must answer:
  #
  #   * `{:http, outcome, method, path}` or `{:http, outcome, method, path,
  #     body}`: the same body as that HTTP door, and at both an answer
  #     (`:answer`: a 2xx and no `isError`) or a refusal (`:refusal`);
  #   * `{:http_error, status, path}`: the same body as the error page that
  #     HTTP door raises to, for an address that names nothing;
  #   * `:ok`: an answer, not a refusal;
  #   * `{:refused, code}`: the tool's own refusal for an input it cannot act
  #     on (an id that names nothing), which still shows the call reached it.
  defp calls(world) do
    %{thread: thread, reply: reply, key: key, profile: profile, run: run} = world
    offer_key = Ecto.UUID.generate()
    # A wording that is not the person's: refused alike at both doors.
    fit = %{"origin" => "quiet.example.net", "version_id" => Ecto.UUID.generate()}

    [
      {"get_patchbay_help", %{}, :ok},
      {"get_webmcp_guide", %{}, :ok},
      {"search_threads", %{"q" => "reservation"},
       {:http, :answer, :get, "/forum/search?q=reservation"}},
      {"get_thread", %{"thread_id" => thread},
       {:http, :answer, :get, "/forum/threads/#{thread}"}},
      {"render_repair_card", %{"thread_id" => thread}, :ok},
      {"get_tool_history", %{"origin" => "https://quiet.example.net", "tool_name" => "amend"},
       {:http, :refusal, :get,
        "/forum/tool-history?origin=https://quiet.example.net&tool_name=amend"}},
      {"read_site_directory", %{}, {:http, :answer, :get, "/sites"}},
      {"list_offer_slots", %{}, {:http, :answer, :get, "/forum/offer-slots"}},
      {"get_agent_profile", %{"profile_id" => profile},
       {:http, :answer, :get, "/api/agents/#{profile}"}},
      {"get_request_status", %{"client_request_id" => key},
       {:http, :answer, :get, "/forum/requests/#{key}"}},
      {"list_my_active_offers", %{}, {:http, :answer, :get, "/forum/my-offers/active"}},
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
       }, :answered},
      # The fix `world!/3` opened is still running, so a second is refused
      # with it, at either door.
      {"request_free_fix", %{"args" => free_fix()},
       {:http, :refusal, :post, "/api/agent/assists", %{"args" => free_fix()}}},
      {"get_assist", %{"run_id" => run}, {:http, :answer, :get, "/api/agent/assists/#{run}"}},
      {"find_known_fixes", %{"site" => "patchbay.help"},
       {:http, :answer, :get, "/known-fixes?site=patchbay.help"}},
      {"get_known_fix", %{"fix_id" => known_fix()},
       {:http, :answer, :get, "/known-fixes/#{known_fix()}"}},
      {"get_subscriptions", %{}, {:http, :answer, :get, "/forum/subscriptions"}},
      {"like_post", %{"thread_id" => thread, "reply_id" => reply},
       {:http, :answer, :post, "/forum/threads/#{thread}/likes", %{"reply_id" => reply}}},
      {"unlike_post", %{"thread_id" => thread},
       {:http, :answer, :delete, "/forum/threads/#{thread}/likes", %{}}},
      {"report_tool_problem", %{"receipt" => "not-a-receipt", "client_request_id" => key},
       {:http, :refusal, :post, "/forum/reports",
        %{"receipt" => "not-a-receipt", "client_request_id" => key}}},
      {"report_tool_on_another_site", other_site_report(), :ok},
      # The report above put amend_reservation on example.net's board.
      {"read_tool_catalog", %{"host" => "example.net", "name" => "amend_reservation"},
       {:http, :answer, :get, "/example.net/tools/amend_reservation"}},
      {"reply_to_report",
       %{
         "report_id" => thread,
         "verdict" => "verified_success",
         "client_request_id" => Ecto.UUID.generate()
       }, :ok},
      {"account_balances", %{}, {:http, :answer, :get, "/tools/account/balances"}},
      {"account_credits_history", %{},
       {:http, :answer, :post, "/tools/account/credits/history", %{}}},
      {"account_points", %{}, {:http, :answer, :get, "/tools/account/points"}},
      {"get_offer_bid_options", %{"slot" => 1},
       {:http, :answer, :post, "/forum/offer-bid-options", %{"slot" => 1}}},
      {"ask_offer_fit", fit, {:http, :refusal, :post, "/forum/offer-fit-checks", fit}},
      {"save_agent_offer", offer(offer_key),
       {:http, :answer, :post, "/forum/my-offers", offer(offer_key)}},
      {"reword_agent_offer", reword(thread),
       {:http, :refusal, :post, "/forum/my-offers/#{thread}/versions",
        Map.delete(reword(thread), "creative_id")}},
      {"read_wallet_bench", %{}, {:http, :answer, :get, "/api/wallet-bench"}},
      {"read_wallet_bench_pair", %{"harness_id" => "H901", "wallet_id" => "W901"},
       {:http, :answer, :get, "/api/wallet-bench/H901/W901"}},
      {"read_wallet_bench_pair", %{"harness_id" => "H999999", "wallet_id" => "W999999"},
       {:http_error, 404, "/api/wallet-bench/H999999/W999999"}}
    ]
  end

  defp free_fix,
    do: %{
      "goal" => "Amend a booking.",
      "site_url" => "https://quiet.example.net",
      "sign_in" => "none"
    }

  defp known_fix, do: hd(Patchbay.Assist.KnownFixes.all()).id

  defp other_site_report do
    %{
      "origin" => "https://quiet.example.net/bookings",
      "tool_name" => "amend_reservation",
      "arguments" => %{"booking" => "B-1"},
      "verdict" => "verified_failure",
      "note" => "The tool said it worked but the booking kept its old date.",
      "client_request_id" => Ecto.UUID.generate()
    }
  end

  defp offer(key),
    do: %{
      "label" => "Booking help",
      "text" => "Bookings amended in one call.",
      "request_key" => key
    }

  defp reword(creative_id),
    do: %{
      "creative_id" => creative_id,
      "text" => "Bookings amended fast.",
      "request_key" => "reword-#{creative_id}"
    }

  defp answered(name, result, {:http, outcome, method, path}, conn, agent),
    do: answered(name, result, {:http, outcome, method, path, nil}, conn, agent)

  defp answered(name, result, {:http, outcome, method, path, body}, conn, agent) do
    over_http =
      conn
      |> recycle()
      |> SignedAgent.sign(agent)
      |> put_req_header("accept", "application/json")
      |> dispatch(PatchbayWeb.Endpoint, method, path, body && Jason.encode!(body))

    assert comparable(body(result)) ==
             over_http.resp_body |> Jason.decode!() |> free() |> comparable(),
           "#{name} answered differently from #{method} #{path}"

    refused? = outcome == :refusal

    assert result["isError"] == refused? and over_http.status >= 400 == refused?,
           "#{name}: expected #{outcome} at both doors, got isError #{result["isError"]} " <>
             "and HTTP #{over_http.status}"
  end

  defp answered(name, result, {:http_error, status, path}, conn, _agent) do
    {^status, _headers, body} =
      assert_error_sent(status, fn ->
        conn |> recycle() |> put_req_header("accept", "application/json") |> get(path)
      end)

    assert result["isError"] and refusal(result) == Jason.decode!(body),
           "#{name} answered differently from GET #{path}"
  end

  defp answered(name, result, :ok, _conn, _agent),
    do: refute(result["isError"], "#{name}: #{inspect(body(result))}")

  defp answered(name, result, {:refused, code}, _conn, _agent),
    do: assert(result["isError"] and code(result) == code, name)

  # An answer from the tool, a refusal of its input included, but never the
  # door's own: the call reached the tool.
  defp answered(name, result, :answered, _conn, _agent) do
    code = if result["isError"], do: code(result)

    refute code in ["agent_not_paired", "http_headers_missing", "rate_limited"],
           "#{name} did not reach its tool: #{code}"
  end

  # The hosted tools are free, so their reads leave out what money a post,
  # reply or author holds (`PatchbayWeb.ForumAPI.Reads`, the `:free`
  # audience), and a profile's money record (`PatchbayWeb.AuthorJSON.profile/2`);
  # the HTTP doors carry them. A profile's public wallet address is in both:
  # a paired agent shows its owner's. Nothing else may differ.
  @money ~w(escrowed_usdc reward_eligibility can_receive_usdc bounties_posted
            answers_accepted tips_given tips_given_usdc tips_received tips_received_usdc)

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

  # A thread asked by `asker` with a reply from `helper`, a free fix `asker`
  # opened, and a Wallet Bench pair with no runs yet. The bench's tables are
  # Techtree's, which Patchbay only reads; the test database has plain ones.
  defp world!(conn, asker, helper) do
    Patchbay.Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_roster (kind, id, name) " <>
        "VALUES ('harness', 'H901', 'Agent 901'), ('wallet', 'W901', 'Wallet 901')"
    )

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

    %{"structuredContent" => %{"run_id" => run}} =
      conn
      |> tools_call(asker, "request_free_fix", %{"args" => free_fix()})
      |> json_response(200)
      |> Map.fetch!("result")

    %{
      thread: thread,
      reply: reply,
      run: run,
      key: question["client_request_id"],
      profile:
        Patchbay.Forum.Report
        |> Ash.get!(thread)
        |> Map.fetch!(:author_profile_id)
        |> Patchbay.Identity.get_profile!()
        |> Map.fetch!(:public_id)
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
