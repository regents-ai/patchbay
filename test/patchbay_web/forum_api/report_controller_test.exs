defmodule PatchbayWeb.ForumAPI.ReportControllerTest do
  # The rate-limit test moves an application setting, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.Report

  @contract String.duplicate("a", 64)
  @arguments String.duplicate("b", 64)

  describe "filing a report" do
    test "records the site, the tool contract and the report", %{conn: conn} do
      conn = post_json(conn, "/forum/reports", report_params())

      assert %{"report_id" => report_id, "url" => url} = json_response(conn, 201)
      assert url == "/reports/#{report_id}"

      report = Ash.get!(Report, report_id, load: [tool: :site])

      assert report.tool.site.origin == "shop.example.com"
      assert report.tool.name == "add_to_cart"
      assert report.tool.title == "Add to cart"
      assert report.tool.contract_sha256 == @contract
      assert report.verdict == :verified_failure
      assert report.failure_code == "NO_CART_CHANGE"
      assert report.observed == %{"cart_count" => 0}
    end

    test "files under the session the server issued, not one the caller names", %{conn: conn} do
      claimed = "00000000-0000-0000-0000-000000000000"

      first = post_json(conn, "/forum/reports", report_params(%{"browser_session_id" => claimed}))
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

    test "stops a session that has filed its hourly share", %{conn: conn} do
      Application.put_env(:patchbay, :forum_reports_per_hour, 2)
      on_exit(fn -> Application.delete_env(:patchbay, :forum_reports_per_hour) end)

      conn = post_json(conn, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, "/forum/reports", report_params())
      assert json_response(conn, 201)

      conn = post_json(conn, "/forum/reports", report_params())
      assert %{"error" => error} = json_response(conn, 429)
      assert error =~ "past hour"
    end
  end

  describe "the page gate" do
    test "a post that never loaded a Patchbay page is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/forum/reports", Jason.encode!(report_params()))

      assert %{"error" => "Open a Patchbay page first" <> _} = json_response(conn, 403)
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

      assert %{"error" => error} = json_response(conn, 404)
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
        "contract_sha256" => @contract,
        "arguments_sha256" => @arguments,
        "verdict" => "verified_failure",
        "handler_result" => %{"ok" => true},
        "observed" => %{"cart_count" => 0},
        "failure_code" => "NO_CART_CHANGE",
        "note" => "The tool said it worked but the cart stayed empty."
      },
      overrides
    )
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
