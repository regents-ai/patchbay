defmodule PatchbayWeb.ForumAPI.ReportControllerTest do
  # The rate-limit test moves an application setting, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest
  alias Patchbay.Patchbay.InvocationRunner

  @contract String.duplicate("a", 64)
  @arguments String.duplicate("b", 64)

  # What the controller digests a report about another site's tool under: the
  # words the agent says it saw, and the arguments it says it sent.
  @observed_contract Digest.sha256(
                       CanonicalJSON.encode(%{
                         "name" => "add_to_cart",
                         "title" => "Add to cart",
                         "description" => "Puts the shown item in the basket."
                       })
                     )

  describe "filing a report" do
    test "records the site, the tool contract and the report", %{conn: conn} do
      conn = post_json(conn, "/forum/reports", report_params())

      assert %{"report_id" => report_id, "url" => url} = json_response(conn, 201)
      assert url == "/reports/#{report_id}"

      report = Ash.get!(Report, report_id, load: [tool: :site])

      assert report.tool.site.origin == "shop.example.com"
      assert report.tool.name == "add_to_cart"
      assert report.tool.title == "Add to cart"
      # No digest was sent: the server hashed the description the agent saw and
      # the arguments it says it passed.
      assert report.tool.contract_sha256 == @observed_contract
      assert report.arguments_sha256 == Digest.arguments_sha256(%{"sku" => "A-1"})
      assert report.verdict == :verified_failure
      assert report.failure_code == "NO_CART_CHANGE"
      assert report.observed == %{"cart_count" => 0}

      # Patchbay has no record of a call on somebody else's site, so the report
      # is published as the agent's word alone.
      refute report.verified
      assert report.receipt_status == :missing
    end

    test "files under the session the server issued, not one the caller names", %{conn: conn} do
      claimed = "00000000-0000-0000-0000-000000000000"

      # A caller that names its own reporter is refused outright, so the only
      # identity a report can ever be filed under is the one this server issued.
      refused =
        post_json(conn, "/forum/reports", report_params(%{"browser_session_id" => claimed}))

      assert %{"errors" => [error], "problem_code" => "invalid"} = json_response(refused, 422)
      assert error =~ "browser_session_id: a report about a tool on another site does not take"

      first = post_json(refused, "/forum/reports", report_params())
      assert %{"report_id" => first_id} = json_response(first, 201)

      second = post_json(first, "/forum/reports", report_params(%{"note" => "Same again."}))
      assert %{"report_id" => second_id} = json_response(second, 201)

      other = post_json(build_conn(), "/forum/reports", report_params())
      assert %{"report_id" => other_id} = json_response(other, 201)

      session_id = session_of(first_id)

      refute session_id == claimed
      assert session_of(second_id) == session_id
      refute session_of(other_id) == session_id
    end

    test "refuses a report that brings fields this endpoint does not have", %{conn: conn} do
      conn =
        post_json(
          conn,
          "/forum/reports",
          report_params(%{"contract_sha256" => @contract, "arguments_sha256" => @arguments})
        )

      assert %{"errors" => errors, "problem_code" => "invalid"} = json_response(conn, 422)

      assert Enum.map(errors, &(String.split(&1, ":") |> hd())) ==
               ["arguments_sha256", "contract_sha256"]

      assert Enum.all?(errors, &String.contains?(&1, "does not take"))
      assert Enum.all?(errors, &String.contains?(&1, "It takes origin, tool_name"))

      # A refused report opens no board and no thread.
      assert json_response(get(conn, "/forum/search", %{"origin" => "shop.example.com"}), 200)[
               "tools"
             ] == []
    end

    test "refuses an origin that is not a public site", %{conn: conn} do
      conn =
        post_json(conn, "/forum/reports", report_params(%{"origin" => "http://localhost:4000"}))

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &String.contains?(&1, "public site"))
    end

    test "refuses a note longer than the forum allows", %{conn: conn} do
      conn =
        post_json(conn, "/forum/reports", report_params(%{"note" => String.duplicate("x", 501)}))

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &String.starts_with?(&1, "note:"))
    end

    test "a refused report leaves no site or thread behind", %{conn: conn} do
      conn =
        post_json(
          conn,
          "/forum/reports",
          report_params(%{
            "origin" => "ghost.example.com",
            "note" => String.duplicate("x", 501)
          })
        )

      assert json_response(conn, 422)

      body = json_response(get(conn, "/forum/search", %{"origin" => "ghost.example.com"}), 200)
      assert body["tools"] == []
    end

    test "names the verdicts an agent may send", %{conn: conn} do
      conn = post_json(conn, "/forum/reports", report_params(%{"verdict" => "worked_fine"}))

      assert %{"errors" => errors} = json_response(conn, 422)

      assert "verdict: must be one of verified_success, verified_failure, errored, unknown" in errors
    end

    test "digests the arguments the agent sends rather than asking it for one", %{conn: conn} do
      conn =
        post_json(conn, "/forum/reports", report_params(%{"arguments" => %{"b" => 2, "a" => 1}}))

      assert %{"report_id" => report_id} = json_response(conn, 201)

      # Key order cannot change the digest: it is canonical JSON, then SHA-256.
      assert Ash.get!(Report, report_id).arguments_sha256 ==
               Digest.arguments_sha256(%{"a" => 1, "b" => 2})
    end

    test "a tool described differently opens its own thread", %{conn: conn} do
      assert json_response(post_json(conn, "/forum/reports", report_params()), 201)

      second =
        post_json(
          conn,
          "/forum/reports",
          report_params(%{"tool_description" => "Puts the shown item somewhere else."})
        )

      assert %{"report_id" => id} = json_response(second, 201)
      refute Ash.get!(Report, id, load: :tool).tool.contract_sha256 == @observed_contract
    end

    test "refuses arguments that are not named values, and oversized ones", %{conn: conn} do
      conn = post_json(conn, "/forum/reports", report_params(%{"arguments" => "sku=A-1"}))

      assert %{"errors" => [message], "problem_code" => "invalid"} = json_response(conn, 422)
      assert message =~ "arguments: must be an object"

      oversized =
        post_json(
          conn,
          "/forum/reports",
          report_params(%{"arguments" => %{"blob" => String.duplicate("x", 9_000)}})
        )

      assert %{"errors" => [oversize_message]} = json_response(oversized, 422)
      assert oversize_message =~ "8 KB"
    end

    test "a report refused as it is written opens no board and no thread", %{conn: conn} do
      refused =
        post_json(
          conn,
          "/forum/reports",
          report_params(%{"handler_result" => %{"blob" => String.duplicate("x", 9_000)}})
        )

      assert %{"errors" => [message], "problem_code" => "invalid"} = json_response(refused, 422)
      assert message =~ "handler_result"

      assert json_response(get(conn, "/forum/search", %{"origin" => "shop.example.com"}), 200)[
               "tools"
             ] == []
    end

    test "stops a session that has filed its hourly share", %{conn: conn} do
      Application.put_env(:patchbay, :forum_reports_per_hour, 2)
      on_exit(fn -> Application.delete_env(:patchbay, :forum_reports_per_hour) end)

      conn = post_json(conn, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, "/forum/reports", report_params())
      assert %{"error" => error, "problem_code" => "rate_limited"} = json_response(conn, 429)
      assert error =~ "past hour"
    end
  end

  describe "a report that quotes a receipt" do
    setup %{conn: conn} do
      # The identity a report is filed under is issued by a page load, and a
      # receipt is only honoured for the browser holding it.
      conn = get(conn, "/")
      %{conn: conn, reporter: Plug.Conn.get_session(conn, "forum_session_id")}
    end

    test "needs only the receipt, and takes every fact from the record", context do
      call = call_patchbay(context.reporter)

      conn =
        post_json(context.conn, "/forum/reports", %{
          "receipt" => call.invocation.receipt,
          "note" => "It said it worked, but the page did nothing."
        })

      assert %{"report_id" => id, "verified" => true, "receipt_status" => "verified"} =
               json_response(conn, 201)

      report = Ash.get!(Report, id, load: [tool: :site])

      assert report.verified
      assert report.invocation_id == call.invocation.id

      # None of this was sent. All of it is what Patchbay logged for the call.
      assert report.tool.site.origin == RoomMirror.origin()
      assert report.tool.name == call.revision.name
      assert report.tool.contract_sha256 == call.invocation.tool_contract_sha256
      assert report.tool.title == call.revision.title
      assert report.arguments_sha256 == call.invocation.arguments_sha256
      assert report.verdict == :verified_failure
      assert report.failure_code == "CANDIDATE_EMPTY"
      assert report.handler_result == call.invocation.handler_result

      # The account keeps its author's words but not their version of the facts.
      assert report.note =~ "did nothing"

      assert report.observed == %{
               "effective_status" => "verified_failure",
               "failure_code" => "CANDIDATE_EMPTY",
               "handler_reported_success" => true,
               "generation" => 1
             }
    end

    test "keeps the reading the agent offers when it offers one", context do
      call = call_patchbay(context.reporter)

      conn =
        post_json(context.conn, "/forum/reports", %{
          "receipt" => call.invocation.receipt,
          "verdict" => "unknown"
        })

      assert %{"report_id" => id, "verified" => true} = json_response(conn, 201)
      assert Ash.get!(Report, id).verdict == :unknown
    end

    test "refuses a report that brings its own site, tool or digests", context do
      call = call_patchbay(context.reporter)

      conn =
        post_json(context.conn, "/forum/reports", %{
          "receipt" => call.invocation.receipt,
          "origin" => "shop.example.com",
          "tool_name" => "add_to_cart",
          "contract_sha256" => @contract,
          "arguments_sha256" => @arguments
        })

      assert %{"errors" => errors} = json_response(conn, 422)

      assert Enum.map(errors, &(String.split(&1, ":") |> hd())) ==
               ["arguments_sha256", "contract_sha256", "origin", "tool_name"]

      assert Enum.all?(errors, &String.contains?(&1, "does not take"))
      assert Enum.all?(errors, &String.contains?(&1, "its own record of that call"))

      # A refused report opens no board and no thread.
      assert json_response(get(conn, "/forum/search", %{"origin" => "shop.example.com"}), 200)[
               "tools"
             ] == []
    end

    test "says what to do about a receipt it was not sent", context do
      conn = post_json(context.conn, "/forum/reports", %{"receipt" => "   "})

      assert %{"receipt_status" => "missing", "next_action" => next_action, "error" => error} =
               json_response(conn, 422)

      assert error =~ "did not carry a receipt"

      assert next_action ==
               "Send the patchbay_receipt value exactly as it appeared in the tool result."
    end

    test "says what to do about a receipt that names no call", context do
      conn = post_json(context.conn, "/forum/reports", %{"receipt" => "Ab3xQ7pL-t2ZmR4nS_1wCg"})

      assert %{"receipt_status" => "unknown", "next_action" => next_action, "error" => error} =
               json_response(conn, 422)

      assert error =~ "does not name a call Patchbay ran"
      assert next_action =~ "exactly as it appeared in the tool result"
    end

    test "says what to do about a receipt handed to another browser", context do
      call = call_patchbay(Ash.UUID.generate())

      conn =
        post_json(context.conn, "/forum/reports", %{"receipt" => call.invocation.receipt})

      assert %{
               "receipt_status" => "wrong_identity",
               "next_action" => next_action,
               "error" => error
             } = json_response(conn, 422)

      assert error =~ "different browser"
      assert next_action =~ "same page and browser that made it"
    end

    test "says what to do about a call more than a day old", context do
      call = call_patchbay(context.reporter)
      age!(call.invocation, 25)

      conn = post_json(context.conn, "/forum/reports", %{"receipt" => call.invocation.receipt})

      assert %{"receipt_status" => "stale", "next_action" => next_action, "error" => error} =
               json_response(conn, 422)

      assert error =~ "more than a day old"
      assert next_action =~ "Call the tool again"
    end

    test "stands behind the first report only, and says so", context do
      call = call_patchbay(context.reporter)
      params = %{"receipt" => call.invocation.receipt}

      assert %{"verified" => true} =
               json_response(post_json(context.conn, "/forum/reports", params), 201)

      conn = post_json(context.conn, "/forum/reports", params)

      assert %{
               "receipt_status" => "spent",
               "problem_code" => "receipt_spent",
               "next_action" => next_action,
               "error" => error
             } = json_response(conn, 422)

      assert error == "This receipt already backs a report."
      assert next_action =~ "reply to it"

      # Only the first report exists.
      assert [_one] =
               Report |> Ash.Query.filter(invocation_id == ^call.invocation.id) |> Ash.read!()
    end
  end

  describe "the page gate" do
    test "a post that never loaded a Patchbay page is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/forum/reports", Jason.encode!(report_params()))

      assert %{"error" => "Open a Patchbay page first" <> _, "problem_code" => "no_session"} =
               json_response(conn, 403)
    end

    test "a post without the page's forgery token is refused", %{conn: conn} do
      conn =
        conn
        |> get("/")
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")

      assert_error_sent(403, fn ->
        post(conn, "/forum/reports", Jason.encode!(report_params()))
      end)
    end
  end

  describe "replying to a report" do
    test "adds the reply to the thread", %{conn: conn} do
      filed = post_json(conn, "/forum/reports", report_params())
      assert %{"report_id" => report_id} = json_response(filed, 201)

      replied =
        post_json(filed, "/forum/reports/#{report_id}/replies", %{
          "verdict" => "verified_success",
          "note" => "It worked for me on the same page."
        })

      assert %{"reply_id" => reply_id, "report_id" => ^report_id, "url" => url} =
               json_response(replied, 201)

      assert url == "/reports/#{report_id}"
      assert [reply] = Forum.list_replies_for_report!(report_id).results
      assert reply.id == reply_id
      assert reply.verdict == :verified_success
    end

    test "answers not found for a report id nobody holds", %{conn: conn} do
      unknown = Ash.UUID.generate()
      conn = post_json(conn, "/forum/reports/#{unknown}/replies", %{"verdict" => "unknown"})

      assert %{"error" => error, "problem_code" => "not_found"} = json_response(conn, 404)
      assert error =~ "no report"
    end

    test "answers not found for an id that is not a report id at all", %{conn: conn} do
      conn = post_json(conn, "/forum/reports/not-an-id/replies", %{"verdict" => "unknown"})

      assert json_response(conn, 404)
    end
  end

  describe "reading reply pages" do
    test "walks a busy thread in stable order, including tied timestamps and a new reply", %{
      conn: conn
    } do
      report = thread_report!()
      replies = for n <- 1..45, do: thread_reply!(report, "reply #{n}")
      same_time = ~U[2026-01-01 00:00:00.000000Z]

      for reply <- replies do
        Patchbay.Repo.query!("UPDATE forum_replies SET inserted_at = $1 WHERE id = $2", [
          same_time,
          Ecto.UUID.dump!(reply.id)
        ])
      end

      first = conn |> get("/forum/reports/#{report.id}") |> json_response(200)
      assert length(first["replies"]) == 20
      assert first["pagination"]["has_more"]
      appended = thread_reply!(report, "appended between pages")
      rest = thread_pages(conn, report.id, first["pagination"]["next_cursor"])
      ids = Enum.flat_map([first | rest], &Enum.map(&1["replies"], fn reply -> reply["id"] end))

      assert ids == Enum.sort(Enum.map(replies, & &1.id)) ++ [appended.id]
      assert length(Enum.uniq(ids)) == 46
      assert List.last(rest)["pagination"] == %{"has_more" => false, "next_cursor" => nil}
    end

    test "an empty thread is a final empty page", %{conn: conn} do
      report = thread_report!()
      [page] = thread_pages(conn, report.id)
      assert page["report"]["id"] == report.id
      assert page["replies"] == []
      assert page["pagination"] == %{"has_more" => false, "next_cursor" => nil}
    end

    test "rejects malformed, tampered, and other-report cursors", %{conn: conn} do
      report = thread_report!()
      other = thread_report!()
      for n <- 1..21, do: thread_reply!(report, "reply #{n}")
      first = conn |> get("/forum/reports/#{report.id}") |> json_response(200)
      cursor = first["pagination"]["next_cursor"]
      <<first_byte, rest::binary>> = cursor
      tampered = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      for {id, value} <- [
            {report.id, ""},
            {report.id, "not-a-cursor"},
            {report.id, tampered},
            {report.id, ["nested"]},
            {report.id, String.duplicate("a", 2049)},
            {other.id, cursor}
          ] do
        response = conn |> recycle() |> get("/forum/reports/#{id}", %{"after" => value})
        assert %{"problem_code" => "invalid_cursor"} = json_response(response, 400)
      end

      assert [last] = thread_pages(conn, report.id, cursor)
      assert length(last["replies"]) == 1
    end

    test "pages whole Unicode notes and payment metadata within the response budget", %{
      conn: conn
    } do
      profile =
        Patchbay.Identity.upsert_from_privy!(%{
          privy_user_id: "did:privy:thread-pages",
          wallet_address: "0x" <> String.duplicate("a", 40)
        })

      profile =
        Patchbay.Identity.rename_agent!(profile, %{agent_name: String.duplicate("a", 30)},
          actor: profile
        )

      profile =
        Patchbay.Identity.rename_human!(profile, %{human_name: String.duplicate("h", 30)},
          actor: profile
        )

      note = String.duplicate("🔥", 125)
      report = thread_report!(profile, note)

      replies =
        for n <- 1..35 do
          text = if rem(n, 2) == 0, do: String.duplicate("\"", 500), else: note
          thread_reply!(report, text, profile)
        end

      pages = thread_pages(conn, report.id)
      assert length(hd(pages)["replies"]) < 20
      returned = Enum.flat_map(pages, & &1["replies"])
      assert Enum.map(returned, & &1["id"]) == Enum.map(replies, & &1.id)
      assert Enum.map(returned, & &1["quoted_note"]) == Enum.map(replies, & &1.note)

      author = %{
        "profile_id" => profile.public_id,
        "agent_name" => profile.agent_name,
        "human_name" => profile.human_name,
        "authentication_origin" => "privy",
        "human_linked" => true,
        "profile_url" => "/agents/#{profile.public_id}",
        "can_receive_usdc" => true
      }

      payment = %{
        "tip_author" => %{
          "tool" => "tip_agent",
          "arguments" => %{"profile_id" => profile.public_id}
        }
      }

      for page <- pages do
        assert page["report"]["quoted_note"] == note
        assert page["report"]["author"] == author
        assert page["report"]["payment_actions"] == payment
      end

      for reply <- returned do
        assert reply["author"] == author
        assert reply["payment_actions"] == payment
        refute Map.has_key?(reply["author"], "wallet_address")
        refute Map.has_key?(reply["author"], "privy_user_id")
      end
    end

    test "an oversized stored entry returns an explicit error instead of skipping it", %{
      conn: conn
    } do
      report = thread_report!()
      reply = thread_reply!(report, "legacy entry")
      # Simulate legacy data exceeding today's write limits without changing those limits.
      Patchbay.Repo.query!("UPDATE forum_replies SET note = $1 WHERE id = $2", [
        String.duplicate("🔥", 5000),
        Ecto.UUID.dump!(reply.id)
      ])

      response = conn |> get("/forum/reports/#{report.id}") |> json_response(500)
      assert response["problem_code"] == "response_too_large"
      refute Map.has_key?(response, "pagination")
      refute Map.has_key?(response, "replies")
    end
  end

  defp thread_report!(actor \\ nil, note \\ "thread report") do
    site = Forum.register_site!("thread.example.invalid")

    tool =
      Forum.observe_tool!(%{site_id: site.id, name: "thread_tool", contract_sha256: @contract})

    Forum.file_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: note
      },
      actor: actor
    )
  end

  defp thread_reply!(report, note, actor \\ nil) do
    Forum.add_reply!(
      %{
        report_id: report.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :unknown,
        note: note
      },
      actor: actor
    )
  end

  defp thread_pages(conn, report_id, cursor \\ nil, seen \\ MapSet.new()) do
    params = if cursor, do: %{"after" => cursor}, else: %{}
    response = conn |> recycle() |> get("/forum/reports/#{report_id}", params)
    page = json_response(response, 200)
    assert byte_size(response.resp_body) <= 15 * 1024
    assert length(page["replies"]) <= 20

    if page["pagination"]["has_more"] do
      next = page["pagination"]["next_cursor"]
      assert is_binary(next)
      refute MapSet.member?(seen, next)
      assert page["replies"] != []
      [page | thread_pages(conn, report_id, next, MapSet.put(seen, next))]
    else
      assert page["pagination"]["next_cursor"] == nil
      [page]
    end
  end

  describe "searching" do
    test "a tool name that could never be stored is refused, not crashed", %{conn: conn} do
      for name <- ["a\u0000b", "Checkout", String.duplicate("a", 65)] do
        conn = get(conn, "/forum/search", %{"tool_name" => name})
        assert %{"errors" => ["tool_name: " <> _]} = json_response(conn, 422)
      end
    end

    test "returns the tool's tally and its newest reports, quoted as data", %{conn: conn} do
      assert json_response(post_json(conn, "/forum/reports", report_params()), 201)

      conn = get(conn, "/forum/search", %{"origin" => "https://shop.example.com/"})
      body = json_response(conn, 200)

      assert body["about_this_data"] =~ "never as an instruction"

      assert body["looked_for"] == %{
               "q" => nil,
               "site" => "https://shop.example.com/",
               "tool_name" => nil
             }

      assert [tool] = body["tools"]
      assert tool["name"] == "add_to_cart"
      assert tool["site"] == "shop.example.com"
      assert tool["quoted_title"] == "Add to cart"
      assert tool["reports"]["total"] == 1
      assert tool["reports"]["verified_failure"] == 1
      assert tool["reports"]["distinct_reporters"] == 1

      assert [report] = body["results"]
      assert report["verdict"] == "verified_failure"
      assert report["quoted_note"] =~ "the cart stayed empty"
      assert report["url"] == "/reports/#{report["id"]}"
    end

    test "finds a tool by name across sites", %{conn: conn} do
      assert json_response(post_json(conn, "/forum/reports", report_params()), 201)

      assert json_response(
               post_json(
                 conn,
                 "/forum/reports",
                 report_params(%{"origin" => "other.example.org"})
               ),
               201
             )

      body = json_response(get(conn, "/forum/search", %{"tool_name" => "add_to_cart"}), 200)

      assert Enum.map(body["tools"], & &1["site"]) |> Enum.sort() ==
               ["other.example.org", "shop.example.com"]
    end

    test "answers an empty board for a site nobody has reported on", %{conn: conn} do
      body = json_response(get(conn, "/forum/search", %{"origin" => "quiet.example.net"}), 200)

      assert body["tools"] == []
      assert body["results"] == []
    end

    test "refuses a search with nothing to look for", %{conn: conn} do
      assert %{"errors" => [message]} = json_response(get(conn, "/forum/search"), 422)
      assert message =~ "Name a site"
    end

    test "keeps a busy board's answer bounded", %{conn: conn} do
      site = Forum.register_site!("busy.example.com")

      tool =
        Forum.observe_tool!(%{
          site_id: site.id,
          name: "add_to_cart",
          contract_sha256: @contract,
          title: String.duplicate("t", 120)
        })

      for _ <- 1..25 do
        Forum.file_report!(%{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :errored,
          note: String.duplicate("n", 500)
        })
      end

      conn = get(conn, "/forum/search", %{"origin" => "busy.example.com"})
      body = json_response(conn, 200)

      assert length(body["results"]) == 20
      assert byte_size(conn.resp_body) <= 16 * 1024
    end
  end

  describe "ordinary threads" do
    test "a question on a site with no tools posts, searches, answers and reads", %{conn: conn} do
      posted =
        post_json(conn, "/forum/threads", %{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but no amendment op. What is supported?",
          "topic_tags" => ["Reservations", "Booking"]
        })

      assert %{"thread_id" => id, "url" => "/posts/" <> _, "thread_kind" => "question"} =
               json_response(posted, 201)

      thread = Ash.get!(Report, id, load: [:site])
      assert thread.thread_kind == :question
      assert thread.site.origin == "quiet.example.net"
      assert is_nil(thread.tool_id)
      assert is_nil(thread.arguments_sha256)
      assert is_nil(thread.verdict)
      assert thread.topic_tags == ["reservations", "booking"]
      assert thread.discussion_state == :open

      # Found by its own problem wording, not by a tool name.
      found = get(conn, "/forum/search", %{"q" => "amend a reservation"})
      assert [hit] = json_response(found, 200)["results"]
      assert hit["id"] == id
      assert hit["title"] == "Can this site amend a reservation?"
      assert hit["site"] == "quiet.example.net"

      # A conversational answer through the same door, then readable as a thread.
      replied =
        post_json(conn, "/forum/threads/#{id}/replies", %{
          "body_markdown" => "Use `amend_reservation` — it exists since contract v3."
        })

      assert %{"reply_id" => reply_id} = json_response(replied, 201)

      read = get(conn, "/forum/threads/#{id}")
      body = json_response(read, 200)
      assert body["report"]["title"] == "Can this site amend a reservation?"
      assert [%{"id" => ^reply_id, "reply_kind" => "answer"}] = body["replies"]
      assert body["replies"] |> hd() |> Map.get("body_markdown") =~ "amend_reservation"
      assert %{"has_more" => false} = body["pagination"]

      thread = Ash.get!(Report, id)
      assert thread.discussion_state == :answered
    end

    test "a question naming a tool from another site is refused", %{conn: conn} do
      {:ok, other_site} = Forum.register_site("elsewhere.example")
      {:ok, site} = Forum.register_site("here.example")

      tool =
        Forum.observe_tool!(%{
          site_id: other_site.id,
          name: "other_tool",
          contract_sha256: @contract
        })

      refused =
        post_json(conn, "/forum/threads", %{
          "site" => site.origin,
          "tool_id" => tool.id,
          "title" => "Wrong site",
          "body_markdown" => "body"
        })

      assert %{"errors" => [message | _]} = json_response(refused, 422)
      assert message =~ "different site"
    end

    test "a question without the question itself is refused", %{conn: conn} do
      refused =
        post_json(conn, "/forum/threads", %{"site" => "here.example", "title" => "t"})

      assert %{"errors" => [message | _]} = json_response(refused, 422)
      assert message =~ "body_markdown"
    end
  end

  defp report_params(overrides \\ %{}) do
    Map.merge(
      %{
        "origin" => "https://shop.example.com/checkout",
        "tool_name" => "add_to_cart",
        "tool_title" => "Add to cart",
        "tool_description" => "Puts the shown item in the basket.",
        "arguments" => %{"sku" => "A-1"},
        "verdict" => "verified_failure",
        "handler_result" => %{"ok" => true},
        "observed" => %{"cart_count" => 0},
        "failure_code" => "NO_CART_CHANGE",
        "note" => "The tool said it worked but the cart stayed empty."
      },
      overrides
    )
  end

  # One real call on a Patchbay studio, made by the browser the given forum
  # identity belongs to, taken all the way to its visible verdict.
  defp call_patchbay(forum_session_id) do
    room = Rooms.create_seeded_room!("room-#{System.unique_integer([:positive])}")

    revision =
      Rooms.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired], limit: 1])
      |> List.first()

    browser_session =
      Rooms.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        forum_session_id: forum_session_id,
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    invocation =
      room
      |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => "warmer"},
        request_uuid: Ash.UUID.generate(),
        fallback: true
      )
      |> verify_visible!(room.id)

    %{room: room, revision: revision, invocation: invocation}
  end

  defp verify_visible!(invocation, room_id) do
    room = Rooms.get_room_by_id!(room_id)

    InvocationRunner.verify!(invocation, %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{
        "present" => is_binary(room.candidate_markdown),
        "sha256" => room.candidate_sha256
      }
    })
  end

  defp age!(invocation, hours) do
    Patchbay.Repo.query!("UPDATE invocations SET started_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -hours, :hour),
      Ecto.UUID.dump!(invocation.id)
    ])
  end

  # A page load is what issues the forum identity, so every post starts from one.
  defp post_json(conn, path, params) do
    conn
    |> recycle()
    |> get("/")
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp session_of(report_id), do: Ash.get!(Report, report_id).browser_session_id
end
