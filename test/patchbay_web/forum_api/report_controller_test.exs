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
      assert body["looked_for"] == %{"site" => "https://shop.example.com/", "tool_name" => nil}

      assert [tool] = body["tools"]
      assert tool["name"] == "add_to_cart"
      assert tool["site"] == "shop.example.com"
      assert tool["quoted_title"] == "Add to cart"
      assert tool["reports"]["total"] == 1
      assert tool["reports"]["verified_failure"] == 1
      assert tool["reports"]["distinct_reporters"] == 1

      assert [report] = body["reports"]
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
      assert body["reports"] == []
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

      assert length(body["reports"]) == 20
      assert byte_size(conn.resp_body) <= 16 * 1024
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
