defmodule PatchbayWeb.ConnectorBoundaryTest do
  use PatchbayWeb.ConnCase, async: false
  alias Patchbay.Forum.{AnswerUse, Report}

  setup do
    {:ok, signer} = Siwa.LocalSigner.new()
    secret = :crypto.strong_rand_bytes(32)

    broker =
      start_supervised!(
        {Bandit,
         plug: fn conn, _ ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)

           result =
             Siwa.verify_authenticated_request(Jason.decode!(body),
               secret: secret,
               audience: "patchbay",
               wallet_audiences: ["patchbay"]
             )

           {status, body} =
             case result do
               {:ok, %{claims: claims}} ->
                 {200,
                  %{
                    code: "http_envelope_valid",
                    data: %{
                      verified: true,
                      walletAddress: claims["sub"],
                      chainId: 8453,
                      principal: %{
                        kind: "wallet",
                        wallet_address: claims["sub"],
                        chain_id: 8453,
                        audience: "patchbay"
                      }
                    }
                  }}

               {:error, _} ->
                 {401, %{error: %{code: "invalid_proof"}}}
             end

           conn
           |> put_resp_content_type("application/json")
           |> send_resp(status, Jason.encode!(body))
         end,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(broker)
    previous = Application.get_env(:patchbay, :wallet_author)
    Application.put_env(:patchbay, :wallet_author, broker_url: "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.put_env(:patchbay, :wallet_author, previous) end)
    %{signer: signer, secret: secret}
  end

  test "connector search traverses every machine record after response-size trimming", c do
    previous = Application.get_env(:patchbay, :forum_reports_per_hour)
    Application.put_env(:patchbay, :forum_reports_per_hour, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :forum_reports_per_hour, previous),
        else: Application.delete_env(:patchbay, :forum_reports_per_hour)
    end)

    args = question()

    posted_ids =
      for index <- 1..21 do
        posted =
          tool(
            c,
            "patchbay_post",
            Map.merge(args, %{
              "title" => "Shared pagination question #{index}",
              "client_request_id" => Ecto.UUID.generate()
            })
          )

        refute posted["isError"]
        posted["structuredContent"]["thread_id"]
      end

    traversed =
      Enum.reduce_while(1..21, {[], 0}, fn _, {seen, offset} ->
        result =
          rpc("/mcp/agent", "tools/call", %{
            name: "patchbay_search",
            arguments: %{
              origin: args["site"],
              since_minutes: "60",
              offset: Integer.to_string(offset)
            }
          })["result"]

        refute result["isError"]
        data = result["structuredContent"]["data"]
        ids = Enum.map(data["results"], & &1["id"])
        assert ids != []
        assert MapSet.disjoint?(MapSet.new(seen), MapSet.new(ids))
        if offset == 0, do: assert(length(ids) < 20)

        if data["pagination"]["has_more"] do
          next_offset = data["pagination"]["next_offset"]
          assert next_offset == offset + length(ids)
          {:cont, {seen ++ ids, next_offset}}
        else
          assert is_nil(data["pagination"]["next_offset"])
          {:halt, seen ++ ids}
        end
      end)

    assert is_list(traversed)
    assert length(traversed) == 21
    assert MapSet.new(traversed) == MapSet.new(posted_ids)
  end

  test "exact body, audience and replay proof govern publication", c do
    args = question()
    before = Ash.count!(Report)
    assert unsigned("patchbay_post", args).status == 401
    request = signed(c, "patchbay_post", args)
    altered = %{request | body: String.replace(request.body, "Find a slot", "Book a slot")}
    assert send_signed(altered).status == 401
    assert send_signed(signed(c, "patchbay_post", args, "other-product")).status == 401
    assert Ash.count!(Report) == before
    assert send_signed(request).status == 200
    assert send_signed(request).status == 401
    assert Ash.count!(Report) == before + 1
  end

  test "shared search, authorized public ask, retrieval and outcome preserve identity and retry context",
       c do
    args = question()

    search =
      rpc("/mcp/agent", "tools/call", %{
        name: "patchbay_search",
        arguments: %{origin: args["site"]}
      })

    refute search["result"]["isError"]
    posted = tool(c, "patchbay_post", args)
    refute posted["isError"]
    id = posted["structuredContent"]["thread_id"]
    report = Ash.get!(Report, id)
    assert report.operation_id == posted["structuredContent"]["operation_id"]
    assert report.machine_principal == "profile:" <> report.author_profile_id
    assert is_nil(report.browser_session_id)
    assert is_nil(report.tool_id)
    assert report.agent_environment == "declared-agent"
    assert report.target_interface == "webmcp"
    assert report.submission_transport == :mcp_agent
    old_limit = Application.get_env(:patchbay, :forum_reports_per_hour)
    Application.put_env(:patchbay, :forum_reports_per_hour, 1)

    on_exit(fn ->
      if old_limit,
        do: Application.put_env(:patchbay, :forum_reports_per_hour, old_limit),
        else: Application.delete_env(:patchbay, :forum_reports_per_hour)
    end)

    repeated = tool(c, "patchbay_post", args)
    assert repeated["structuredContent"]["operation_id"] == report.operation_id
    assert repeated["structuredContent"]["repeated"]

    assert tool(c, "patchbay_post", Map.put(args, "agent_environment", "other"))[
             "structuredContent"
           ]["problem_code"] == "request_reused"

    {:ok, {_thread, reply}} =
      PatchbayWeb.ForumAPI.Participation.post_reply(Ecto.UUID.generate(), nil, id, %{
        "body_markdown" => "Use the listed service identifier.",
        "reply_kind" => "answer"
      })

    read =
      rpc("/mcp/agent", "tools/call", %{
        name: "patchbay_check_updates",
        arguments: %{thread_id: id}
      })

    refute read["result"]["isError"]

    assert %{
             "operation_id" => operation_id,
             "submission_transport" => "mcp_agent",
             "target_interface" => "webmcp",
             "agent_environment" => "declared-agent",
             "environment_is_declared" => true
           } = read["result"]["structuredContent"]["data"]["report"]["operation_context"]

    assert operation_id == report.operation_id
    assert Jason.encode!(read) =~ reply.id

    assert {:ok, legacy_use} =
             PatchbayWeb.ForumAPI.Participation.record_answer_use(
               Ecto.UUID.generate(),
               nil,
               reply.id,
               %{"task_token" => "browser-task", "outcome" => "not_tried"}
             )

    assert is_nil(legacy_use.operation_id)
    assert {:error, _} = Patchbay.Forum.record_answer_use(%{})

    use_args = %{
      "reply_id" => reply.id,
      "task_token" => "task-1",
      "outcome" => "did_not_work",
      "visibility" => "public",
      "agent_environment" => "declared-agent",
      "target_interface" => "webmcp"
    }

    outcome = tool(c, "patchbay_record_outcome", use_args)
    refute outcome["isError"]
    use_id = outcome["structuredContent"]["record_id"]
    corrected = tool(c, "patchbay_record_outcome", Map.put(use_args, "outcome", "worked"))

    assert corrected["structuredContent"]["operation_id"] ==
             outcome["structuredContent"]["operation_id"]

    assert Ash.get!(AnswerUse, use_id).outcome == :worked
    stored_use = Ash.get!(AnswerUse, use_id)

    assert {:error, _} =
             Patchbay.Forum.record_answer_use(%{
               reply_id: stored_use.reply_id,
               principal: stored_use.principal,
               task_token: stored_use.task_token,
               outcome: :did_not_work
             })

    assert Ash.get!(AnswerUse, use_id).outcome == :worked
    {:ok, actor} = Patchbay.Identity.upsert_from_wallet(%{wallet_address: c.signer.address})

    assert {:error, _} =
             Patchbay.Forum.record_answer_use(
               stored_use
               |> Map.take([
                 :reply_id,
                 :principal,
                 :task_token,
                 :outcome,
                 :operation_id,
                 :operation_name,
                 :submission_transport,
                 :target_interface,
                 :agent_environment
               ])
               |> Map.put(:target_interface, "other"),
               actor: actor
             )

    assert Ash.get!(AnswerUse, use_id).target_interface == "webmcp"

    assert tool(c, "patchbay_record_outcome", Map.put(use_args, "target_interface", "http"))[
             "isError"
           ]
  end

  test "held threads and disallowed content cannot leak or gain outcome writes", c do
    args = question()

    for rejected <- [
          Map.put(args, "raw_conversation", "private"),
          Map.put(args, "visibility", "private"),
          Map.put(args, "body_markdown", "Authorization: Bearer credential"),
          Map.put(args, "title", "api_\u200Bkey=synthetic-value"),
          Map.put(args, "operation_id", Ecto.UUID.generate())
        ] do
      assert tool(c, "patchbay_post", rejected)["isError"]
    end

    assert Ash.count!(Report) == 0
    posted = tool(c, "patchbay_post", args)
    id = posted["structuredContent"]["thread_id"]

    {:ok, {_, reply}} =
      PatchbayWeb.ForumAPI.Participation.post_reply(Ecto.UUID.generate(), nil, id, %{
        "body_markdown" => "Answer",
        "reply_kind" => "answer"
      })

    Ash.get!(Report, id)
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: :quarantined})
    |> Ash.update!(authorize?: false)

    assert tool(c, "patchbay_post", args)["structuredContent"]["problem_code"] == "not_found"

    result =
      rpc("/mcp/agent", "tools/call", %{name: "patchbay_read", arguments: %{thread_id: id}})

    assert result["result"]["isError"]
    refute Jason.encode!(result) =~ args["body_markdown"]

    outcome =
      tool(c, "patchbay_record_outcome", %{
        "reply_id" => reply.id,
        "task_token" => "held",
        "outcome" => "worked",
        "visibility" => "public",
        "target_interface" => "webmcp",
        "agent_environment" => "declared-agent"
      })

    assert outcome["isError"]
    {:ok, actor} = Patchbay.Identity.upsert_from_wallet(%{wallet_address: c.signer.address})

    assert {:error, _} =
             Patchbay.Forum.record_answer_use(
               %{
                 reply_id: reply.id,
                 principal: "profile:" <> actor.id,
                 task_token: "direct-held",
                 outcome: :worked,
                 operation_id: Ecto.UUID.generate(),
                 operation_name: :record_answer_use,
                 submission_transport: :mcp_agent,
                 target_interface: "webmcp",
                 agent_environment: "declared-agent"
               },
               actor: actor
             )

    assert Ash.count!(AnswerUse) == 0
  end

  defp question,
    do: %{
      "site" => "https://connector-#{Ecto.UUID.generate()}.invalid",
      "title" => "Find a slot",
      "body_markdown" => "Which service identifier should I use?",
      "client_request_id" => Ecto.UUID.generate(),
      "visibility" => "public",
      "target_interface" => "webmcp",
      "agent_environment" => "declared-agent"
    }

  defp rpc(path, method, params),
    do:
      post(build_conn(), path, %{jsonrpc: "2.0", id: 1, method: method, params: params})
      |> json_response(200)

  defp unsigned(name, args),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp/agent",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: args}
        })
      )

  defp tool(c, name, args),
    do: signed(c, name, args) |> send_signed() |> json_response(200) |> Map.fetch!("result")

  defp signed(c, name, args, audience \\ "patchbay") do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => c.signer.address,
          "chain_id" => 8453,
          "aud" => audience,
          "key_id" => c.signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: c.secret
      )

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{method: "POST", path: "/mcp/agent", body: body},
        receipt,
        c.signer,
        secret: c.secret,
        audience: audience,
        wallet_audiences: [audience]
      )

    request
  end

  defp send_signed(request) do
    conn =
      Enum.reduce(request.headers, build_conn(), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn |> put_req_header("content-type", "application/json") |> post("/mcp/agent", request.body)
  end
end
