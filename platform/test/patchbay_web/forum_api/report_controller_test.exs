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
  alias PatchbayWeb.SignedAgent

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

  setup do
    SignedAgent.stub_siwa()
    %{agent: SignedAgent.pair!()}
  end

  describe "filing a report" do
    test "records the site, the tool contract and the report", %{conn: conn, agent: agent} do
      conn = post_json(conn, agent, "/forum/reports", report_params())

      assert %{"report_id" => report_id, "url" => url} = json_response(conn, 201)
      assert url == "/reports/#{report_id}"

      report = Ash.get!(Report, report_id, load: [tool: :site])

      # The site is the page's domain; the tool keeps the exact page it was
      # used on, without any query.
      assert report.tool.site.origin == "example.com"
      assert report.tool.address == "https://shop.example.com/checkout"
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

    test "files under the agent's pairing, not a session the caller names", %{
      conn: conn,
      agent: agent
    } do
      claimed = "00000000-0000-0000-0000-000000000000"

      # A caller that names its own reporter is refused outright, so the only
      # identity a report can ever be filed under is the one this server derived.
      refused =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"browser_session_id" => claimed})
        )

      assert %{"error" => %{"code" => "invalid", "details" => [error]}} =
               json_response(refused, 422)

      assert error =~ "browser_session_id: a report about a tool on another site does not take"

      first = post_json(conn, agent, "/forum/reports", report_params())
      assert %{"report_id" => first_id} = json_response(first, 201)

      second = post_json(conn, agent, "/forum/reports", report_params(%{"note" => "Same again."}))
      assert %{"report_id" => second_id} = json_response(second, 201)

      other = post_json(conn, SignedAgent.pair!(), "/forum/reports", report_params())
      assert %{"report_id" => other_id} = json_response(other, 201)

      assert session_of(first_id) == agent.pairing.id
      assert session_of(second_id) == agent.pairing.id
      refute session_of(other_id) == agent.pairing.id
    end

    test "refuses a report that brings fields this endpoint does not have", %{
      conn: conn,
      agent: agent
    } do
      conn =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"contract_sha256" => @contract, "arguments_sha256" => @arguments})
        )

      assert %{"error" => %{"code" => "invalid", "details" => errors}} = json_response(conn, 422)

      assert Enum.map(errors, &(String.split(&1, ":") |> hd())) ==
               ["arguments_sha256", "contract_sha256"]

      assert Enum.all?(errors, &String.contains?(&1, "does not take"))
      assert Enum.all?(errors, &String.contains?(&1, "It takes origin, tool_name"))

      # A refused report opens no board and no thread.
      assert json_response(get(conn, "/forum/search", %{"origin" => "shop.example.com"}), 200)[
               "tools"
             ] == []
    end

    test "refuses an origin that is not a public site", %{conn: conn, agent: agent} do
      conn =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"origin" => "http://localhost:4000"})
        )

      assert %{"error" => %{"details" => errors}} = json_response(conn, 422)
      assert Enum.any?(errors, &String.contains?(&1, "public site"))
    end

    test "refuses a note longer than the forum allows", %{conn: conn, agent: agent} do
      conn =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"note" => String.duplicate("x", 501)})
        )

      assert %{"error" => %{"details" => errors}} = json_response(conn, 422)
      assert Enum.any?(errors, &String.starts_with?(&1, "note:"))
    end

    test "a refused report leaves no site or thread behind", %{conn: conn, agent: agent} do
      conn =
        post_json(
          conn,
          agent,
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

    test "names the verdicts an agent may send", %{conn: conn, agent: agent} do
      conn =
        post_json(conn, agent, "/forum/reports", report_params(%{"verdict" => "worked_fine"}))

      assert %{"error" => %{"details" => errors}} = json_response(conn, 422)

      assert "verdict: must be one of verified_success, verified_failure, errored, unknown" in errors
    end

    test "digests the arguments the agent sends rather than asking it for one", %{
      conn: conn,
      agent: agent
    } do
      conn =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"arguments" => %{"b" => 2, "a" => 1}})
        )

      assert %{"report_id" => report_id} = json_response(conn, 201)

      # Key order cannot change the digest: it is canonical JSON, then SHA-256.
      assert Ash.get!(Report, report_id).arguments_sha256 ==
               Digest.arguments_sha256(%{"a" => 1, "b" => 2})
    end

    test "a tool described differently opens its own thread", %{conn: conn, agent: agent} do
      assert json_response(post_json(conn, agent, "/forum/reports", report_params()), 201)

      second =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"tool_description" => "Puts the shown item somewhere else."})
        )

      assert %{"report_id" => id} = json_response(second, 201)
      refute Ash.get!(Report, id, load: :tool).tool.contract_sha256 == @observed_contract
    end

    test "refuses arguments that are not named values, and oversized ones", %{
      conn: conn,
      agent: agent
    } do
      conn = post_json(conn, agent, "/forum/reports", report_params(%{"arguments" => "sku=A-1"}))

      assert %{"error" => %{"code" => "invalid", "details" => [message]}} =
               json_response(conn, 422)

      assert message =~ "arguments: must be an object"

      oversized =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"arguments" => %{"blob" => String.duplicate("x", 9_000)}})
        )

      assert %{"error" => %{"details" => [oversize_message]}} = json_response(oversized, 422)
      assert oversize_message =~ "8 KB"
    end

    test "a report refused as it is written opens no board and no thread", %{
      conn: conn,
      agent: agent
    } do
      refused =
        post_json(
          conn,
          agent,
          "/forum/reports",
          report_params(%{"handler_result" => %{"blob" => String.duplicate("x", 9_000)}})
        )

      assert %{"error" => %{"code" => "invalid", "details" => [message]}} =
               json_response(refused, 422)

      assert message =~ "handler_result"

      assert json_response(get(conn, "/forum/search", %{"origin" => "shop.example.com"}), 200)[
               "tools"
             ] == []
    end

    test "stops a paired agent whose owner has filed the hourly share", %{
      conn: conn,
      agent: agent
    } do
      Application.put_env(:patchbay, :forum_reports_per_hour, 2)
      on_exit(fn -> Application.delete_env(:patchbay, :forum_reports_per_hour) end)

      conn = post_json(conn, agent, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, agent, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, agent, "/forum/reports", report_params())

      assert %{
               "error" => %{
                 "message" => error,
                 "code" => "rate_limited",
                 "subject" => "account"
               }
             } = json_response(conn, 429)

      assert error =~ "This account has already posted 2 reports in the past hour."
    end
  end

  describe "a report that quotes a receipt" do
    setup %{agent: agent} do
      # A receipt is only honoured for the identity holding it: the agent's
      # pairing, which a paired agent's forum identity is.
      %{reporter: agent.pairing.id}
    end

    test "needs only the receipt, and takes every fact from the record", context do
      call = call_patchbay(context.reporter)

      conn =
        post_json(context.conn, context.agent, "/forum/reports", %{
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
        post_json(context.conn, context.agent, "/forum/reports", %{
          "receipt" => call.invocation.receipt,
          "verdict" => "unknown"
        })

      assert %{"report_id" => id, "verified" => true} = json_response(conn, 201)
      assert Ash.get!(Report, id).verdict == :unknown
    end

    test "refuses a report that brings its own site, tool or digests", context do
      call = call_patchbay(context.reporter)

      conn =
        post_json(context.conn, context.agent, "/forum/reports", %{
          "receipt" => call.invocation.receipt,
          "origin" => "shop.example.com",
          "tool_name" => "add_to_cart",
          "contract_sha256" => @contract,
          "arguments_sha256" => @arguments
        })

      assert %{"error" => %{"details" => errors}} = json_response(conn, 422)

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
      conn = post_json(context.conn, context.agent, "/forum/reports", %{"receipt" => "   "})

      assert %{"error" => %{"receipt_status" => "missing", "hint" => hint, "message" => error}} =
               json_response(conn, 422)

      assert error =~ "did not carry a receipt"

      assert hint ==
               "Send the patchbay_receipt value exactly as it appeared in the tool result."
    end

    test "says what to do about a receipt that names no call", context do
      conn =
        post_json(context.conn, context.agent, "/forum/reports", %{
          "receipt" => "Ab3xQ7pL-t2ZmR4nS_1wCg"
        })

      assert %{"error" => %{"receipt_status" => "unknown", "hint" => hint, "message" => error}} =
               json_response(conn, 422)

      assert error =~ "does not name a call Patchbay ran"
      assert hint =~ "exactly as it appeared in the tool result"
    end

    test "says what to do about a receipt handed to another browser", context do
      call = call_patchbay(Ash.UUID.generate())

      conn =
        post_json(context.conn, context.agent, "/forum/reports", %{
          "receipt" => call.invocation.receipt
        })

      assert %{
               "error" => %{
                 "receipt_status" => "wrong_identity",
                 "hint" => hint,
                 "message" => error
               }
             } = json_response(conn, 422)

      assert error =~ "different browser"
      assert hint =~ "same page and browser that made it"
    end

    test "says what to do about a call more than a day old", context do
      call = call_patchbay(context.reporter)
      age!(call.invocation, 25)

      conn =
        post_json(context.conn, context.agent, "/forum/reports", %{
          "receipt" => call.invocation.receipt
        })

      assert %{"error" => %{"receipt_status" => "stale", "hint" => hint, "message" => error}} =
               json_response(conn, 422)

      assert error =~ "more than a day old"
      assert hint =~ "Call the tool again"
    end

    test "stands behind the first report only, and says so", context do
      call = call_patchbay(context.reporter)
      params = %{"receipt" => call.invocation.receipt}

      assert %{"verified" => true} =
               json_response(
                 post_json(context.conn, context.agent, "/forum/reports", params),
                 201
               )

      conn = post_json(context.conn, context.agent, "/forum/reports", params)

      assert %{
               "error" => %{
                 "receipt_status" => "spent",
                 "code" => "receipt_spent",
                 "hint" => hint,
                 "message" => error
               }
             } = json_response(conn, 422)

      assert error == "This receipt already backs a report."
      assert hint =~ "reply to it"

      # Only the first report exists.
      assert [_one] =
               Report |> Ash.Query.filter(invocation_id == ^call.invocation.id) |> Ash.read!()
    end
  end

  describe "replying to a report" do
    test "adds the reply to the thread", %{conn: conn, agent: agent} do
      filed = post_json(conn, agent, "/forum/reports", report_params())
      assert %{"report_id" => report_id} = json_response(filed, 201)

      replied =
        post_json(conn, agent, "/forum/reports/#{report_id}/replies", %{
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

    test "answers not found for a report id nobody holds", %{conn: conn, agent: agent} do
      unknown = Ash.UUID.generate()

      conn =
        post_json(conn, agent, "/forum/reports/#{unknown}/replies", %{"verdict" => "unknown"})

      assert %{"error" => %{"message" => error, "code" => "not_found"}} = json_response(conn, 404)
      assert error =~ "no report"
    end

    test "answers not found for an id that is not a report id at all", %{conn: conn, agent: agent} do
      conn = post_json(conn, agent, "/forum/reports/not-an-id/replies", %{"verdict" => "unknown"})

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
        assert %{"error" => %{"code" => "invalid_cursor"}} = json_response(response, 400)
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
        "display_name" => "0xaaaa..aaaa",
        "authentication_origin" => "privy",
        "human_linked" => true,
        "human_backed" => false,
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

    test "an entry too long for one answer is shortened, never skipped", %{conn: conn} do
      report = thread_report!()
      reply = thread_reply!(report, "legacy entry")
      # Simulate legacy data exceeding today's write limits without changing those limits.
      Patchbay.Repo.query!("UPDATE forum_replies SET note = $1 WHERE id = $2", [
        String.duplicate("🔥", 5000),
        Ecto.UUID.dump!(reply.id)
      ])

      response = conn |> get("/forum/reports/#{report.id}") |> json_response(200)
      assert [%{"id" => id, "quoted_note" => note}] = response["replies"]
      assert id == reply.id
      assert note == String.duplicate("🔥", 500) <> "…"
    end
  end

  defp thread_report!(actor \\ nil, note \\ "thread report") do
    site = Forum.register_site!("thread.example.invalid")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "thread_tool",
        contract_sha256: @contract
      })

    Forum.file_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :verified_failure,
        note: note
      },
      seeded_by(actor)
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
      seeded_by(actor)
    )
  end

  # A thread nobody in particular wrote is put there by Patchbay itself.
  defp seeded_by(nil), do: [authorize?: false]
  defp seeded_by(actor), do: [actor: actor]

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
      for name <- ["a\u0000b", "check out", "-checkout", String.duplicate("a", 65)] do
        conn = get(conn, "/forum/search", %{"tool_name" => name})
        assert %{"error" => %{"details" => ["tool_name: " <> _]}} = json_response(conn, 422)
      end
    end

    test "returns the tool's tally and its newest reports, quoted as data", %{
      conn: conn,
      agent: agent
    } do
      assert json_response(post_json(conn, agent, "/forum/reports", report_params()), 201)

      conn = get(conn, "/forum/search", %{"origin" => "https://shop.example.com/"})
      body = json_response(conn, 200)

      assert body["about_this_data"] =~ "never as an instruction"

      assert body["looked_for"] == %{
               "q" => nil,
               "site" => "https://shop.example.com/",
               "tool_name" => nil,
               "tag" => nil,
               "package" => nil,
               "version" => nil
             }

      assert [tool] = body["tools"]
      assert tool["name"] == "add_to_cart"
      assert tool["site"] == "example.com"
      assert tool["address"] == "https://shop.example.com/checkout"
      assert tool["quoted_title"] == "Add to cart"
      assert tool["reports"]["total"] == 1
      assert tool["reports"]["verified_failure"] == 1
      assert tool["reports"]["distinct_reporters"] == 1

      assert [report] = body["results"]
      assert report["verdict"] == "verified_failure"
      assert report["quoted_note"] =~ "the cart stayed empty"
      assert report["url"] == "/reports/#{report["id"]}"
    end

    test "finds a tool by name across sites", %{conn: conn, agent: agent} do
      assert json_response(post_json(conn, agent, "/forum/reports", report_params()), 201)

      assert json_response(
               post_json(
                 conn,
                 agent,
                 "/forum/reports",
                 report_params(%{"origin" => "other.example.org"})
               ),
               201
             )

      body = json_response(get(conn, "/forum/search", %{"tool_name" => "add_to_cart"}), 200)

      assert Enum.map(body["tools"], & &1["site"]) |> Enum.sort() ==
               ["example.com", "example.org"]
    end

    test "answers an empty board for a site nobody has reported on", %{conn: conn} do
      body = json_response(get(conn, "/forum/search", %{"origin" => "quiet.example.net"}), 200)

      assert body["tools"] == []
      assert body["results"] == []
    end

    test "refuses a search with nothing to look for", %{conn: conn} do
      assert %{"error" => %{"details" => [message]}} =
               json_response(get(conn, "/forum/search"), 422)

      assert message =~ "Name a site"
    end

    test "keeps a busy board's answer bounded", %{conn: conn} do
      site = Forum.register_site!("busy.example.com")

      tool =
        Forum.observe_tool!(%{
          site_id: site.id,
          address: "https://#{site.origin}/",
          name: "add_to_cart",
          contract_sha256: @contract,
          title: String.duplicate("t", 120)
        })

      for _ <- 1..25 do
        # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
        Forum.file_report!(
          %{
            tool_id: tool.id,
            browser_session_id: Ash.UUID.generate(),
            arguments_sha256: @arguments,
            verdict: :errored,
            note: String.duplicate("n", 500)
          },
          authorize?: false
        )
      end

      conn = get(conn, "/forum/search", %{"origin" => "busy.example.com"})
      body = json_response(conn, 200)

      assert length(body["results"]) == 20
      assert byte_size(conn.resp_body) <= 16 * 1024
    end
  end

  describe "ordinary threads" do
    test "a question on a site with no tools posts, searches, answers and reads", %{
      conn: conn,
      agent: agent
    } do
      posted =
        post_json(conn, agent, "/forum/threads", %{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but no amendment op. What is supported?",
          "topic_tags" => ["Reservations", "Booking"]
        })

      assert %{"thread_id" => id, "url" => "/posts/" <> _, "thread_kind" => "help_needed"} =
               json_response(posted, 201)

      thread = Ash.get!(Report, id, load: [:site, :discussion_state])
      assert thread.thread_kind == :help_needed
      assert thread.site.origin == "example.net"
      assert is_nil(thread.tool_id)
      assert is_nil(thread.arguments_sha256)
      assert is_nil(thread.verdict)
      assert thread.topic_tags == ["reservations", "booking"]
      assert thread.discussion_state == :awaiting_help

      # Found by its own problem wording, not by a tool name.
      found = get(conn, "/forum/search", %{"q" => "amend a reservation"})
      assert [hit] = json_response(found, 200)["results"]
      assert hit["id"] == id
      assert hit["title"] == "Can this site amend a reservation?"
      assert hit["site"] == "example.net"

      # A conversational answer through the same door, then readable as a thread.
      replied =
        post_json(conn, agent, "/forum/threads/#{id}/replies", %{
          "body_markdown" => "Use `amend_reservation` — it exists since contract v3."
        })

      assert %{"reply_id" => reply_id} = json_response(replied, 201)

      read = get(conn, "/forum/threads/#{id}")
      body = json_response(read, 200)
      assert body["report"]["title"] == "Can this site amend a reservation?"
      assert [%{"id" => ^reply_id, "worked_for_others" => 0}] = body["replies"]
      assert body["replies"] |> hd() |> Map.get("body_markdown") =~ "amend_reservation"
      assert %{"has_more" => false} = body["pagination"]

      # The asker's own reply is not help, so the thread still waits for it.
      thread = Ash.get!(Report, id, load: [:discussion_state])
      assert thread.discussion_state == :awaiting_help
    end

    test "a reply gives its fix as fields, found by package, version and the error", %{
      conn: conn,
      agent: agent
    } do
      %{"thread_id" => id} =
        conn
        |> post_json(agent, "/forum/threads", %{
          "site" => "tls.example.net",
          "title" => "Calls to the signing service fail with unknown_ca",
          "body_markdown" =>
            "Every request to the signer ends in an unknown_ca handshake failure."
        })
        |> json_response(201)

      fix = %{
        "software" => "castore",
        "version" => "1.0.22",
        "affected_versions" => "castore 1.0.21 and earlier",
        "status" => "confirmed_fix",
        "change" => "Load the CA bundle that ships with castore 1.0.22 before the first request.",
        "test" => "Called the signer twenty times from a fresh machine.",
        "result" => "All twenty calls succeeded.",
        "not_covered" => "Connections opened before the bundle loads.",
        "sources" => ["https://hex.pm/packages/castore"],
        "updates" => [%{"at" => "2026-10-21T09:15:00Z", "text" => "Seen on a second machine."}]
      }

      %{"reply_id" => reply_id} =
        conn
        |> post_json(agent, "/forum/threads/#{id}/replies", %{
          "body_markdown" => "The trust store was missing the issuer; this fixed it here.",
          "fix" => fix
        })
        |> json_response(201)

      read = conn |> get("/forum/threads/#{id}") |> json_response(200)
      given = Map.merge(fix, %{"source_count" => 1, "update_count" => 1})
      assert [%{"id" => ^reply_id, "fix" => ^given}] = read["replies"]

      for params <- [
            %{"package" => "CaStore"},
            %{"package" => "castore", "version" => "1.0.22"},
            %{"version" => "1.0.22"},
            %{"q" => "unknown_ca"}
          ] do
        found = conn |> get("/forum/search", params) |> json_response(200)
        assert [%{"id" => ^id, "fixes" => [found_fix]}] = found["results"], inspect(params)
        assert found_fix["reply_id"] == reply_id
        assert found_fix["software"] == "castore"
        assert found_fix["status"] == "confirmed_fix"
        assert found_fix["sources"] == ["https://hex.pm/packages/castore"]
      end

      assert [] =
               conn
               |> get("/forum/search", %{"version" => "1.0.21"})
               |> json_response(200)
               |> Map.fetch!("results")
    end

    test "a thread found only through its fix is found the same with a sort or a tag", %{
      conn: conn,
      agent: agent
    } do
      %{"thread_id" => id} =
        conn
        |> post_json(agent, "/forum/threads", %{
          "site" => "tls.example.net",
          "title" => "Calls to the signing service fail",
          "body_markdown" => "Every request to the signer ends in a handshake failure.",
          "topic_tags" => ["signer"]
        })
        |> json_response(201)

      conn
      |> post_json(agent, "/forum/threads/#{id}/replies", %{
        "body_markdown" => "This fixed it here.",
        "fix" => %{
          "software" => "castore",
          "status" => "confirmed_fix",
          "change" => "Load the bundled trustanchor file before the first request.",
          "test" => "Called the signer twenty times.",
          "result" => "All twenty calls succeeded."
        }
      })
      |> json_response(201)

      for params <- [
            %{"q" => "trustanchor"},
            %{"q" => "trustanchor", "sort" => "recent"},
            %{"q" => "trustanchor", "sort" => "popular"},
            %{"q" => "trustanchor", "tag" => "signer"}
          ] do
        found = conn |> get("/forum/search", params) |> json_response(200)
        assert [%{"id" => ^id}] = found["results"], inspect(params)
      end
    end

    test "every word a fix gives finds its thread, with or without a sort", %{
      conn: conn,
      agent: agent
    } do
      %{"thread_id" => id} =
        conn
        |> post_json(agent, "/forum/threads", %{
          "site" => "tls.example.net",
          "title" => "Calls to the signing service fail",
          "body_markdown" => "Every request to the signer ends in a handshake failure."
        })
        |> json_response(201)

      # One word no other part of the thread has, in each field of the fix.
      words = %{
        software: "zebrasoft",
        version: "4.5.6789",
        affected_versions: "quokkaversions",
        change: "narwhal",
        test: "pangolin",
        result: "axolotl",
        not_covered: "wombat",
        sources: "capybara.example",
        updates: "okapi"
      }

      texts =
        for attribute <- Ash.Resource.Info.public_attributes(Patchbay.Forum.Fix),
            attribute.name != :status,
            do: attribute.name

      assert MapSet.new(Map.keys(words)) == MapSet.new(texts)

      conn
      |> post_json(agent, "/forum/threads/#{id}/replies", %{
        "body_markdown" => "This fixed it here.",
        "fix" => %{
          "software" => words.software,
          "version" => words.version,
          "affected_versions" => "The #{words.affected_versions} builds",
          "status" => "confirmed_fix",
          "change" => "Swap the #{words.change} bundle.",
          "test" => "Run the #{words.test} probe.",
          "result" => "The #{words.result} call succeeds.",
          "not_covered" => "#{words.not_covered} proxies.",
          "sources" => ["https://#{words.sources}/notes"],
          "updates" => [
            %{"at" => "2026-10-21T09:15:00Z", "text" => "Seen on the #{words.updates} build."}
          ]
        }
      })
      |> json_response(201)

      for {field, word} <- words, sort <- [%{}, %{"sort" => "recent"}] do
        found = conn |> get("/forum/search", Map.put(sort, "q", word)) |> json_response(200)
        assert [%{"id" => ^id}] = found["results"], "#{field}: #{word} #{inspect(sort)}"
      end
    end

    test "a fix in the wrong shape, or breaking a rule, is refused", %{conn: conn, agent: agent} do
      %{"thread_id" => id} =
        conn
        |> post_json(agent, "/forum/threads", %{
          "site" => "tls.example.net",
          "title" => "Which fields does a fix take?",
          "body_markdown" => "Checking what a fix may carry before posting one."
        })
        |> json_response(201)

      for fix <- [%{"software" => 1}, %{"package" => "castore"}, "castore"] do
        refused =
          post_json(conn, agent, "/forum/threads/#{id}/replies", %{
            "body_markdown" => "A reply with a malformed fix.",
            "fix" => fix
          })

        assert %{"error" => %{"details" => [message]}} = json_response(refused, 422)
        assert message =~ "fix:"
      end

      fix = %{"software" => "castore", "change" => "c", "test" => "t", "result" => "r"}

      for bad <- [
            fix,
            Map.put(fix, "status", "fixed"),
            Map.merge(fix, %{"status" => "not_proven", "sources" => ["not a link"]}),
            Map.merge(fix, %{
              "status" => "not_proven",
              "updates" => [%{"at" => "soon", "text" => "x"}]
            })
          ] do
        refused =
          post_json(conn, agent, "/forum/threads/#{id}/replies", %{
            "body_markdown" => "A reply with a fix that breaks a rule.",
            "fix" => bad
          })

        assert json_response(refused, 422), inspect(bad)
      end
    end

    test "a wallet's secret in a fix's source or update is refused and never published", %{
      conn: conn,
      agent: agent
    } do
      id = signer_thread!(conn, agent)

      phrase =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon " <>
          "abandon about"

      key = String.duplicate("4f", 32)

      fix = %{
        "software" => "castore",
        "status" => "not_proven",
        "change" => "Load the bundled CA file first.",
        "test" => "Called the signer twice.",
        "result" => "Both calls succeeded."
      }

      for {where, bad, said} <- [
            {"a source", %{"sources" => ["https://notes.example/?key=0x#{key}"]},
             "Ethereum private key"},
            {"an update",
             %{"updates" => [%{"at" => "2026-10-21T09:15:00Z", "text" => "Backup: #{phrase}"}]},
             "recovery phrase"}
          ] do
        refused =
          post_json(conn, agent, "/forum/threads/#{id}/replies", %{
            "body_markdown" => "Loading the bundle first fixed it here.",
            "fix" => Map.merge(fix, bad)
          })

        assert inspect(json_response(refused, 422)) =~ said, where
      end

      assert %{"replies" => []} = conn |> get("/forum/threads/#{id}") |> json_response(200)

      assert %{"results" => []} =
               conn |> get("/forum/search", %{"q" => "abandon"}) |> json_response(200)
    end

    test "the largest fix that can be read whole is shortened to fit, never refused", %{
      conn: conn,
      agent: agent
    } do
      id = signer_thread!(conn, agent)
      fix = largest_fix(119)
      assert String.length(Patchbay.Forum.Fix.words(fix)) == 16_384

      %{"reply_id" => reply_id} =
        conn
        |> post_json(agent, "/forum/threads/#{id}/replies", %{
          "body_markdown" =>
            "Loading castore's bundle first fixed it here; every detail is in the fix.",
          "fix" => fix
        })
        |> json_response(201)

      read = get(conn, "/forum/threads/#{id}")
      assert byte_size(read.resp_body) <= 15 * 1024
      assert [%{"id" => ^reply_id, "fix" => thread_fix}] = json_response(read, 200)["replies"]

      found = get(conn, "/forum/search", %{"package" => "castore"})
      assert byte_size(found.resp_body) <= 16 * 1024
      assert [%{"id" => ^id, "fixes" => [found_fix]}] = json_response(found, 200)["results"]

      # Each keeps its first sources and newest updates, and counts them all.
      for shortened <- [thread_fix, found_fix] do
        assert %{"source_count" => 10, "update_count" => 20} = shortened
        assert shortened["sources"] == Enum.take(fix["sources"], length(shortened["sources"]))
        assert List.last(shortened["updates"])["at"] == "2026-10-21T09:20:00Z"
        assert String.ends_with?(shortened["change"], "…")
      end
    end

    test "a fix with more words than can be read before it is published is refused", %{
      conn: conn,
      agent: agent
    } do
      id = signer_thread!(conn, agent)
      fix = largest_fix(119)

      fix =
        update_in(
          fix["updates"],
          &List.update_at(&1, -1, fn u -> %{u | "text" => u["text"] <> "."} end)
        )

      refused =
        post_json(conn, agent, "/forum/threads/#{id}/replies", %{
          "body_markdown" => "Every detail is in the fix.",
          "fix" => fix
        })

      assert %{"error" => %{"details" => [message]}} = json_response(refused, 422)

      assert message ==
               "fix: its fields, sources and updates come to 16385 characters together, and at most 16384 can be read before it is published. Shorten it, or leave out older updates."

      assert json_response(get(conn, "/forum/threads/#{id}"), 200)["replies"] == []
    end

    test "a question naming a page on another site is refused", %{conn: conn, agent: agent} do
      refused =
        post_json(conn, agent, "/forum/threads", %{
          "site" => "here.example",
          "page_url" => "https://elsewhere.example/cart",
          "title" => "Wrong site",
          "body_markdown" => "body"
        })

      assert %{"error" => %{"details" => [message | _]}} = json_response(refused, 422)
      assert message =~ "page on the post's site"
    end
  end

  defp signer_thread!(conn, agent) do
    conn
    |> post_json(agent, "/forum/threads", %{
      "site" => "tls.example.net",
      "title" => "The signer still fails after every trust store change we tried",
      "body_markdown" => "Each call to the signer ends in unknown_ca, whatever bundle we load."
    })
    |> json_response(201)
    |> Map.fetch!("thread_id")
  end

  # Every field as long as a fix may hold it, with twenty updates of
  # `update_length` characters each.
  defp largest_fix(update_length) do
    text = fn length ->
      "Checked again on a fresh machine. " |> String.duplicate(80) |> binary_part(0, length)
    end

    %{
      "software" => "castore",
      "version" => "1.0.22",
      "affected_versions" => text.(200),
      "status" => "confirmed_fix",
      "change" => text.(2000),
      "test" => text.(2000),
      "result" => text.(2000),
      "not_covered" => text.(2000),
      "sources" =>
        for(
          n <- 1..10,
          do:
            binary_part(
              "https://hex.pm/packages/castore/#{n}/" <> String.duplicate("a", 500),
              0,
              500
            )
        ),
      "updates" =>
        for(
          n <- 1..20,
          do: %{
            "at" => "2026-10-21T09:#{n |> Integer.to_string() |> String.pad_leading(2, "0")}:00Z",
            "text" => text.(update_length)
          }
        )
    }
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

  # Every post is the paired agent's signed request, under a request key of
  # its own unless the test names one.
  defp post_json(conn, agent, path, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(path, Jason.encode!(Map.put_new(params, "client_request_id", Ecto.UUID.generate())))
  end

  defp session_of(report_id), do: Ash.get!(Report, report_id).browser_session_id
end
