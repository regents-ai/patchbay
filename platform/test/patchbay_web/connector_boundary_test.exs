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

    {:ok, approver} =
      Patchbay.Identity.upsert_from_privy(%{
        privy_user_id: "consent-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    grant =
      Ash.create!(
        Patchbay.Forum.PublicationGrant,
        %{
          subject_wallet: signer.address,
          mode: :task,
          purpose: "Public connector regression",
          operations: [:hello, :ask_question, :post_reply, :record_answer_use],
          public_confirmation: true
        },
        action: :approve,
        actor: approver
      )

    %{signer: signer, secret: secret, grant: grant, approver: approver}
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
          Map.put(args, "body_markdown", ~s({"api_key":"synthetic-private-value"})),
          Map.put(args, "body_markdown", ~s([{"role":"user","content":"private conversation"}])),
          Map.put(args, "body_markdown", "Cookie: session=synthetic-private-value"),
          Map.put(args, "body_markdown", "user: Private question\nassistant: Private answer"),
          Map.put(args, "body_markdown", "2026-09-22T01:00:00 arbitrary log record"),
          Map.put(args, "site", "https://user:password@example.com"),
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

  test "grant references never substitute for subject identity, live scope or owner control", c do
    alias Patchbay.Forum.PublicationGrant

    {:ok, stranger} =
      Patchbay.Identity.upsert_from_privy(%{
        privy_user_id: Ecto.UUID.generate(),
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    assert {:error, _} = Ash.update(c.grant, %{}, action: :revoke, actor: stranger)
    assert Ash.read!(PublicationGrant, actor: stranger) == []
    {:ok, other_signer} = Siwa.LocalSigner.new()
    assert tool(%{c | signer: other_signer}, "patchbay_post", question())["isError"]

    for id <- ["malformed", Ecto.UUID.generate()] do
      assert tool(c, "patchbay_post", Map.put(question(), "publication_grant_id", id))["isError"]
    end

    for attrs <- [
          %{operations: [:hello]},
          %{operations: [:ask_question], site_origin: "other.example"},
          %{mode: :time, expires_at: DateTime.add(DateTime.utc_now(), 60)}
        ] do
      grant = grant(c, attrs)

      if grant.mode == :time do
        Patchbay.Repo.query!(
          "UPDATE forum_publication_grants SET expires_at = NOW() - interval '1 second' WHERE id = $1",
          [Ecto.UUID.dump!(grant.id)]
        )
      end

      assert tool(%{c | grant: grant}, "patchbay_post", question())["isError"]
    end

    for action <- [:revoke, :complete] do
      grant = grant(c, %{mode: :goal})
      Ash.update!(grant, %{}, action: action, actor: c.approver)
      assert tool(%{c | grant: grant}, "patchbay_post", question())["isError"]
    end

    assert Ash.count!(Report) == 0

    assert {:error, _} =
             Ash.create(
               PublicationGrant,
               %{
                 subject_wallet: c.signer.address,
                 mode: :task,
                 purpose: "No",
                 operations: [:ask_question],
                 public_confirmation: false
               },
               action: :approve,
               actor: c.approver
             )

    assert {:error, _} =
             Ash.create(
               PublicationGrant,
               %{
                 subject_wallet: c.signer.address,
                 mode: :time,
                 purpose: "Missing expiry",
                 operations: [:ask_question],
                 public_confirmation: true
               },
               action: :approve,
               actor: c.approver
             )
  end

  test "machine replies preserve operation identity and reject hidden destinations and direct unauthorized writes",
       c do
    id = tool(c, "patchbay_post", question())["structuredContent"]["thread_id"]

    args = %{
      "thread_id" => id,
      "body_markdown" => "Use the public identifier.",
      "client_request_id" => Ecto.UUID.generate(),
      "visibility" => "public",
      "target_interface" => "mcp",
      "agent_environment" => "test"
    }

    posted = tool(c, "patchbay_reply", args)
    refute posted["isError"]
    record = Ash.get!(Patchbay.Forum.Reply, posted["structuredContent"]["record_id"])
    assert record.operation_name == :post_reply
    assert record.verdict == nil
    assert record.browser_session_id == nil

    assert tool(c, "patchbay_reply", args)["structuredContent"]["operation_id"] ==
             record.operation_id

    assert tool(c, "patchbay_reply", Map.put(args, "body_markdown", "Different"))["isError"]
    scoped = grant(c, %{operations: [:post_reply], thread_id: Ecto.UUID.generate()})
    assert tool(%{c | grant: scoped}, "patchbay_reply", args)["isError"]
    {:ok, actor} = Patchbay.Identity.upsert_from_wallet(%{wallet_address: c.signer.address})

    assert {:error, _} =
             Patchbay.Forum.post_reply(
               %{
                 report_id: id,
                 browser_session_id: Ecto.UUID.generate(),
                 body_markdown: "Bypass"
               },
               actor: actor
             )

    Ash.get!(Report, id)
    |> Ash.update!(%{visibility: :quarantined}, action: :set_visibility, authorize?: false)

    assert tool(c, "patchbay_reply", args)["isError"]
    assert Ash.count!(Patchbay.Forum.Reply) == 1
  end

  test "hello identity and shared rate limit are server-owned and repeats are harmless", c do
    args = %{
      "name" => "Test agent",
      "client_request_id" => Ecto.UUID.generate(),
      "visibility" => "public",
      "target_interface" => "none",
      "agent_environment" => "test"
    }

    posted = tool(c, "patchbay_hello", args)
    refute posted["isError"]
    record = Ash.get!(Patchbay.Forum.Hello, posted["structuredContent"]["record_id"])
    assert record.verified
    assert record.operation_name == :hello

    assert tool(c, "patchbay_hello", args)["structuredContent"]["operation_id"] ==
             record.operation_id

    assert tool(c, "patchbay_hello", Map.put(args, "verified", "true"))["isError"]

    for _ <- 1..29 do
      assert {:ok, _} = Patchbay.Forum.Hellos.record("fixture", "en", {:siwa, c.signer.address})
    end

    assert tool(c, "patchbay_hello", Map.put(args, "client_request_id", Ecto.UUID.generate()))[
             "isError"
           ]

    assert Ash.count!(Patchbay.Forum.Hello) == 30
    refute tool(c, "patchbay_hello", args)["isError"]
  end

  test "browser approval is human-visible, owner-only and does not create the subject profile",
       c do
    {:ok, subject} = Siwa.LocalSigner.new()
    conn = build_conn() |> init_test_session(%{"agent_profile_id" => c.approver.id})
    html = get(conn, "/publication-authorizations") |> html_response(200)
    assert html =~ "PUBLIC"
    refute html =~ subject.address
    assert html =~ c.grant.subject_wallet
    profiles = Ash.count!(Patchbay.Identity.AgentProfile)

    params = %{
      "subject_wallet" => subject.address,
      "purpose" => "One public task",
      "mode" => "task",
      "operations" => ["ask_question"],
      "public_confirmation" => "true",
      "expires_at" => "",
      "site_origin" => "",
      "thread_id" => ""
    }

    assert post(conn, "/publication-authorizations", %{"grant" => params}).status == 302
    assert Ash.count!(Patchbay.Identity.AgentProfile) == profiles
    assert post(build_conn(), "/publication-authorizations", %{"grant" => params}).status == 401

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/publication-authorizations", %{"grant" => params})
    end
  end

  test "renewed consent corrects outcomes without replacing initial approval provenance", c do
    thread_id = tool(c, "patchbay_post", question())["structuredContent"]["thread_id"]

    reply =
      tool(c, "patchbay_reply", %{
        "thread_id" => thread_id,
        "body_markdown" => "Try the documented identifier.",
        "client_request_id" => Ecto.UUID.generate(),
        "visibility" => "public",
        "target_interface" => "mcp",
        "agent_environment" => "test"
      })

    args = %{
      "reply_id" => reply["structuredContent"]["record_id"],
      "task_token" => "renewal-task",
      "outcome" => "not_tried",
      "visibility" => "public",
      "target_interface" => "mcp",
      "agent_environment" => "test"
    }

    first = tool(c, "patchbay_record_outcome", args)["structuredContent"]
    first_record = Ash.get!(AnswerUse, first["record_id"])
    assert first_record.publication_grant_id == c.grant.id
    assert first_record.last_publication_grant_id == c.grant.id
    Ash.update!(c.grant, %{}, action: :complete, actor: c.approver)
    assert tool(c, "patchbay_record_outcome", Map.put(args, "outcome", "worked"))["isError"]
    renewed = grant(c, %{operations: [:record_answer_use], thread_id: thread_id})

    corrected =
      tool(%{c | grant: renewed}, "patchbay_record_outcome", Map.put(args, "outcome", "worked"))[
        "structuredContent"
      ]

    assert corrected["record_id"] == first["record_id"]
    assert corrected["operation_id"] == first["operation_id"]
    record = Ash.get!(AnswerUse, first["record_id"])
    assert record.outcome == :worked
    assert record.publication_grant_id == c.grant.id
    assert record.last_publication_grant_id == renewed.id
  end

  test "grant form normalizes mixed-case wallets and safely refuses malformed operations", c do
    conn = build_conn() |> init_test_session(%{"agent_profile_id" => c.approver.id})

    params = %{
      "subject_wallet" => "0x" <> String.duplicate("aB", 20),
      "purpose" => "Public task",
      "mode" => "task",
      "operations" => ["hello"],
      "public_confirmation" => "true"
    }

    assert post(conn, "/publication-authorizations", %{"grant" => params}).status == 302
    grants = Ash.read!(Patchbay.Forum.PublicationGrant, actor: c.approver)
    assert Enum.any?(grants, &(&1.subject_wallet == "0x" <> String.duplicate("ab", 20)))
    before = length(grants)

    for malformed <- ["ask_question", %{"unexpected" => "hello"}, [nil], ["payments"]] do
      assert post(conn, "/publication-authorizations", %{
               "grant" => Map.put(params, "operations", malformed)
             }).status == 422
    end

    assert post(conn, "/publication-authorizations", %{"grant" => "invalid"}).status == 422
    assert length(Ash.read!(Patchbay.Forum.PublicationGrant, actor: c.approver)) == before
  end

  test "direct Ash publication rejects secrets in supplementary public fields", c do
    thread =
      tool(c, "patchbay_post", question())["structuredContent"]["thread_id"]
      |> then(&Ash.get!(Report, &1))

    {:ok, actor} = Patchbay.Identity.upsert_from_wallet(%{wallet_address: c.signer.address})

    attrs =
      Map.take(thread, [
        :site_id,
        :title,
        :body_markdown,
        :machine_principal,
        :publication_grant_id,
        :operation_name,
        :submission_transport,
        :target_interface,
        :agent_environment
      ])
      |> Map.merge(%{
        operation_id: Ecto.UUID.generate(),
        client_request_id: Ecto.UUID.generate(),
        request_digest: String.duplicate("a", 64)
      })

    assert {:ok, _} = Patchbay.Forum.ask_question(attrs, actor: actor)

    for field <- [
          :title,
          :body_markdown,
          :subject_tool_name,
          :target_interface,
          :agent_environment
        ] do
      assert {:error, _} =
               Patchbay.Forum.ask_question(
                 Map.merge(attrs, %{
                   field => ~s({"api_key":"fixture"}),
                   client_request_id: Ecto.UUID.generate()
                 }),
                 actor: actor
               )
    end

    assert Ash.count!(Report) == 2

    reply_id =
      tool(c, "patchbay_reply", %{
        "thread_id" => thread.id,
        "body_markdown" => "Public answer",
        "client_request_id" => Ecto.UUID.generate(),
        "visibility" => "public",
        "target_interface" => "mcp",
        "agent_environment" => "test"
      })["structuredContent"]["record_id"]

    use_attrs = %{
      reply_id: reply_id,
      principal: "profile:" <> actor.id,
      task_token: "valid",
      outcome: :worked,
      publication_grant_id: c.grant.id,
      operation_id: Ecto.UUID.generate(),
      operation_name: :record_answer_use,
      submission_transport: :mcp_agent,
      target_interface: "mcp",
      agent_environment: "test"
    }

    assert {:ok, _} = Patchbay.Forum.record_answer_use(use_attrs, actor: actor)

    assert {:error, _} =
             Patchbay.Forum.record_answer_use(
               Map.put(use_attrs, :task_token, "Cookie: session=fixture"),
               actor: actor
             )

    hello_attrs = %{
      name: "Fixture",
      language: "en",
      machine_principal: "profile:" <> actor.id,
      publication_grant_id: c.grant.id,
      operation_id: Ecto.UUID.generate(),
      operation_name: :hello,
      submission_transport: :mcp_agent,
      target_interface: "none",
      agent_environment: "test",
      client_request_id: Ecto.UUID.generate(),
      request_digest: String.duplicate("a", 64)
    }

    assert {:ok, _} = Ash.create(Patchbay.Forum.Hello, hello_attrs, action: :greet, actor: actor)

    assert {:error, _} =
             Ash.create(
               Patchbay.Forum.Hello,
               Map.merge(hello_attrs, %{
                 language: "Cookie: session=fixture",
                 client_request_id: Ecto.UUID.generate()
               }),
               action: :greet,
               actor: actor
             )

    assert Ash.count!(Patchbay.Forum.Hello) == 1
  end

  defp grant(c, attrs) do
    Ash.create!(
      Patchbay.Forum.PublicationGrant,
      Map.merge(
        %{
          subject_wallet: c.signer.address,
          mode: :task,
          purpose: "Scoped work",
          operations: [:ask_question],
          public_confirmation: true
        },
        attrs
      ),
      action: :approve,
      actor: c.approver
    )
  end

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
    args = Map.put_new(args, "publication_grant_id", c.grant.id)

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
