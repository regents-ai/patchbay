defmodule PatchbayWeb.PageBusyTest do
  # A read the database is too busy to answer, wherever it is made, asks to be
  # opened again shortly: a site's page, its Markdown and its live panels, a
  # post's page, an agent's profile, the solved feed and the forum API answer
  # 503 with Retry-After 2, as a page, as Markdown or as the JSON refusal
  # `busy`, and a hosted tool answers the refusal `busy`. A busy read is
  # never taken for a site the board does not have. Each read below waits on a
  # table another connection has locked until PostgreSQL stops it at its time
  # limit, or waits for a connection while every one is taken. A read that
  # fails for any other reason is still a fault.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias PatchbayWeb.SignedAgent

  @busy "Patchbay is too busy to open this page right now."

  setup do
    site = Forum.register_site!("busy-pages.example")
    %{site: site}
  end

  describe "a site's page" do
    test "is busy when its posts cannot be read", %{conn: conn} do
      lock_table("forum_reports")

      assert_busy_page(get(conn, "/busy-pages.example?goal=pay"), "/busy-pages.example?goal=pay")
    end

    test "is busy when its site check cannot be read, even for a site with no board", %{
      conn: conn
    } do
      lock_table("site_checks")

      assert_busy_page(get(conn, "/no-board.example"), "/no-board.example")
    end

    test "is busy when its tools cannot be read, as a page and as Markdown", %{conn: conn} do
      lock_table("forum_tools")

      assert_busy_page(get(conn, "/busy-pages.example"), "/busy-pages.example")

      markdown = conn |> put_req_header("accept", "text/markdown") |> get("/busy-pages.example")
      assert response(markdown, 503) =~ "# " <> @busy
      assert get_resp_header(markdown, "retry-after") == ["2"]
    end

    test "is busy, never a site without a board, when no connection comes free", %{conn: conn} do
      [page] = while_the_connection_is_held([fn -> get(conn, "/busy-pages.example") end])

      assert_busy_page(page, "/busy-pages.example")
      refute get_resp_header(page, "x-robots-tag") == ["noindex"]
    end

    test "is a fault when its posts fail for another reason", %{conn: conn} do
      Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

      assert_error_sent 500, fn -> get(conn, "/busy-pages.example") end
    end

    test "is a fault when its site check fails for another reason", %{conn: conn} do
      Patchbay.Repo.query!("ALTER TABLE site_checks RENAME COLUMN domain TO hidden_away")

      assert_error_sent 500, fn -> get(conn, "/no-board.example") end
    end

    test "is a fault when its tools fail for another reason", %{conn: conn} do
      Patchbay.Repo.query!("ALTER TABLE forum_tools RENAME COLUMN name TO hidden_away")

      assert_error_sent 500, fn ->
        conn |> put_req_header("accept", "text/markdown") |> get("/busy-pages.example")
      end
    end
  end

  describe "a form sent" do
    test "from a site's page is busy, and Try again opens that page", %{conn: conn} do
      lock_table("forum_tools")

      ask = %{"ask" => %{"goal" => "Pay for the cart"}}

      assert_busy_page(post(conn, "/busy-pages.example/threads", ask), "/busy-pages.example")
    end
  end

  describe "a post's page" do
    setup %{site: site} do
      post =
        Forum.ask_question!(
          %{
            site_id: site.id,
            browser_session_id: Ash.UUID.generate(),
            title: "The cart never changed",
            thread_kind: :help_needed,
            body_markdown: "Asked on the board."
          },
          authorize?: false
        )

      %{post: post}
    end

    test "is busy when its view cannot be counted", %{conn: conn, post: post} do
      lock_table("forum_thread_views")

      assert_busy_page(get(conn, PostAddress.path(post)), PostAddress.path(post))
    end

    test "is busy when the reader's follows cannot be read", %{conn: conn, post: post} do
      lock_table("forum_subscriptions")

      assert_busy_page(get(conn, PostAddress.path(post)), PostAddress.path(post))
    end

    test "a like pressed on it is busy, and Try again opens the post", %{conn: conn, post: post} do
      [pressed] =
        while_the_connection_is_held([
          fn -> post(conn, "/posts/#{post.id}/likes", %{"like" => "true"}) end
        ])

      assert_busy_page(pressed, "/posts/#{post.id}")
    end

    test "is a fault when its view fails for another reason", %{conn: conn, post: post} do
      Patchbay.Repo.query!(
        "ALTER TABLE forum_thread_views RENAME COLUMN inserted_at TO hidden_away"
      )

      assert_error_sent 500, fn -> get(conn, PostAddress.path(post)) end
    end

    test "is a fault when the reader's follows fail for another reason", %{
      conn: conn,
      post: post
    } do
      Patchbay.Repo.query!(
        "ALTER TABLE forum_subscriptions RENAME COLUMN scope_kind TO hidden_away"
      )

      assert_error_sent 500, fn -> get(conn, PostAddress.path(post)) end
    end
  end

  describe "the solved feed" do
    test "is busy as JSON to a reader asking for JSON, and as a page otherwise", %{conn: conn} do
      lock_table("forum_reports")

      [as_json, as_page] =
        [
          conn |> put_req_header("accept", "application/json") |> get("/solved.json"),
          get(conn, "/solved.json")
        ]

      assert %{"error" => %{"code" => "busy", "retry_after_seconds" => 2}} =
               json_response(as_json, 503)

      assert get_resp_header(as_json, "retry-after") == ["2"]
      assert_busy_page(as_page, "/solved.json")
    end

    test "is a fault when it fails for another reason", %{conn: conn} do
      Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

      assert_error_sent 500, fn -> get(conn, "/solved.json") end
    end
  end

  describe "the forum API" do
    test "the newest threads are busy when they cannot be read", %{conn: conn} do
      lock_table("forum_reports")

      answer = get(conn, "/forum/search?sort=recent")

      assert %{"error" => %{"code" => "busy", "retry_after_seconds" => 2}} =
               json_response(answer, 503)

      assert get_resp_header(answer, "retry-after") == ["2"]
    end

    test "the newest threads are not busy when they fail for another reason", %{conn: conn} do
      Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

      answer = get(conn, "/forum/search?sort=recent")

      refute match?(%{"error" => %{"code" => "busy"}}, Jason.decode!(answer.resp_body))
      assert get_resp_header(answer, "retry-after") == []
    end

    test "an agent's follows are busy when they cannot be read", %{conn: conn} do
      SignedAgent.stub_siwa()
      agent = SignedAgent.pair!()
      lock_table("forum_subscriptions")

      answer = conn |> SignedAgent.sign(agent) |> get("/forum/subscriptions")

      assert %{"error" => %{"code" => "busy", "retry_after_seconds" => 2}} =
               json_response(answer, 503)

      assert get_resp_header(answer, "retry-after") == ["2"]
    end

    test "an agent's follows are unavailable, not busy, when they fail for another reason", %{
      conn: conn
    } do
      SignedAgent.stub_siwa()
      agent = SignedAgent.pair!()

      Patchbay.Repo.query!(
        "ALTER TABLE forum_subscriptions RENAME COLUMN scope_kind TO hidden_away"
      )

      answer = conn |> SignedAgent.sign(agent) |> get("/forum/subscriptions")

      assert %{"error" => %{"code" => "unavailable"}} = json_response(answer, 503)
      assert get_resp_header(answer, "retry-after") == []
    end
  end

  describe "an agent's profile" do
    setup do
      profile =
        Patchbay.Identity.upsert_from_privy!(%{
          privy_user_id: "did:privy:busy-profile",
          wallet_address: "0x" <> String.duplicate("b", 40)
        })

      %{path: "/agents/#{profile.public_id}", profile: profile}
    end

    test "is busy, never unknown, when no connection comes free",
         %{conn: conn, path: path} = context do
      [page, json, tool] =
        while_the_connection_is_held([
          fn -> get(conn, path) end,
          fn -> get(conn, "/api" <> path) end,
          fn -> busy_tool?(conn, context.profile) end
        ])

      assert_busy_page(page, path)
      assert_busy_json(json)
      assert tool
    end

    test "is busy when its tips cannot be read", %{conn: conn, path: path} do
      lock_table("regent_payments.payment_receipts")

      assert_busy_page(get(conn, path), path)
      assert_busy_json(get(conn, "/api" <> path))
    end

    test "is a fault when its tips fail for another reason", %{conn: conn, path: path} do
      Patchbay.Repo.query!(
        "ALTER TABLE regent_payments.payment_receipts RENAME COLUMN amount_atomic TO hidden_away"
      )

      assert_error_sent 500, fn -> get(conn, path) end
      assert_error_sent 500, fn -> get(conn, "/api" <> path) end
    end

    test "an unknown one is still not found", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/agents/nobody-here") end

      assert json_response(get(conn, "/api/agents/nobody-here"), 404)["error"]["code"] ==
               "not_found"
    end
  end

  describe "the saved faults" do
    test "leave out a read stopped at its time limit" do
      lock_table("site_checks")

      assert {:error, stopped} = Forum.get_site_check("no-board.example")
      assert ignored?(stopped)
    end

    test "leave out a read that found no connection" do
      [no_connection] =
        while_the_connection_is_held([fn -> Forum.get_site_check("no-board.example") end])

      assert {:error, failure} = no_connection
      assert ignored?(failure)
    end

    test "keep a read that failed for another reason" do
      Patchbay.Repo.query!("ALTER TABLE site_checks RENAME COLUMN domain TO hidden_away")

      assert {:error, fault} = Forum.get_site_check("no-board.example")
      refute ignored?(fault)
    end
  end

  # As ErrorTracker records an exception: its name and its printed message.
  defp ignored?(exception) do
    Patchbay.ErrorIgnorer.ignore?(
      %ErrorTracker.Error{
        kind: to_string(exception.__struct__),
        reason: Exception.message(exception)
      },
      %{}
    )
  end

  defp assert_busy_page(answer, try_again) do
    assert html_response(answer, 503) =~ @busy
    assert get_resp_header(answer, "retry-after") == ["2"]

    assert answer
           |> html_response(503)
           |> LazyHTML.from_document()
           |> LazyHTML.query("a.pb-cta")
           |> LazyHTML.attribute("href") == [try_again]
  end

  defp assert_busy_json(answer) do
    assert json_response(answer, 503)["error"]["code"] == "busy"
    assert get_resp_header(answer, "retry-after") == ["2"]
  end

  # The hosted get_agent_profile answers as a tool: a result that is the
  # refusal `busy`, not the address failing.
  defp busy_tool?(conn, profile) do
    call = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{
        "name" => "get_agent_profile",
        "arguments" => %{"profile_id" => profile.public_id}
      }
    }

    %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(call))
      |> json_response(200)

    Jason.decode!(text)["error"]["code"] == "busy"
  end

  # Another connection locks `table` until the test ends, and this test's
  # reads may wait half a second, so a read of `table` is stopped at that
  # limit as a statement past its time is.
  defp lock_table(table) do
    test = self()

    blocker =
      spawn_link(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Patchbay.Repo)
        Patchbay.Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
        send(test, :locked)
        receive do: (:release -> :ok)
      end)

    assert_receive :locked, 5_000
    on_exit(fn -> send(blocker, :release) end)
    Patchbay.Repo.query!("SET LOCAL statement_timeout = 500")
  end

  # Another process holds the test's one database connection while `requests`
  # run together, so every read they make waits in the queue until the
  # sandbox drops it, as when a crowd has every connection.
  defp while_the_connection_is_held(requests) do
    test = self()

    {holder, held} =
      spawn_monitor(fn ->
        Patchbay.Repo.transaction(fn ->
          send(test, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    answers = requests |> Enum.map(&Task.async/1) |> Task.await_many(30_000)
    send(holder, :release)
    assert_receive {:DOWN, ^held, :process, ^holder, :normal}
    answers
  end
end
