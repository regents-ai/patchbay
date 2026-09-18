defmodule PatchbayWeb.Forum.BoardControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Fixtures

  @contract String.duplicate("a", 64)
  @other_contract String.duplicate("b", 64)
  @arguments String.duplicate("c", 64)

  defp site!(origin), do: Forum.register_site!(origin)

  defp tool!(site, attrs \\ %{}) do
    Forum.observe_tool!(
      Map.merge(%{site_id: site.id, name: "checkout", contract_sha256: @contract}, attrs)
    )
  end

  defp report!(tool, attrs \\ %{}) do
    Forum.file_report!(
      Map.merge(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_success
        },
        attrs
      )
    )
  end

  defp reply!(report, attrs) do
    Forum.add_reply!(
      Map.merge(
        %{
          report_id: report.id,
          browser_session_id: Ash.UUID.generate(),
          verdict: :unknown
        },
        attrs
      )
    )
  end

  describe "GET /" do
    test "lists recent reports with site, tool, verdict, and a note snippet", %{conn: conn} do
      site = site!("shop.example")
      tool = tool!(site, %{name: "checkout"})
      report = report!(tool, %{note: "the cart stayed empty", verdict: :verified_failure})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="/posts/#{report.id}")
      assert html =~ "shop.example"
      assert html =~ "checkout"
      assert html =~ "Did not work"
      assert html =~ "the cart stayed empty"
      refute html =~ "A website catches its own broken agent tool"
    end

    test "filters the feed with the same site-or-tool look-up as search", %{conn: conn} do
      quiet = site!("quiet.example") |> tool!(%{name: "search"}) |> report!(%{note: "quiet note"})
      busy = site!("busy.example") |> tool!(%{name: "checkout"}) |> report!(%{note: "busy note"})

      by_site = conn |> get(~p"/?q=busy.example") |> html_response(200)
      assert by_site =~ ~s(href="/posts/#{busy.id}")
      refute by_site =~ ~s(href="/posts/#{quiet.id}")

      by_tool = conn |> get(~p"/?q=search") |> html_response(200)
      assert by_tool =~ ~s(href="/posts/#{quiet.id}")
      refute by_tool =~ ~s(href="/posts/#{busy.id}")
    end

    test "an empty search keeps the query and offers a reset", %{conn: conn} do
      html = conn |> get(~p"/?q=unreported.example.invalid") |> html_response(200)
      document = LazyHTML.from_document(html)
      assert html =~ "No matching discussions"

      assert Enum.count(
               LazyHTML.query(
                 document,
                 ~s(input[type="search"][name="q"][value="unreported.example.invalid"])
               )
             ) == 1

      assert Enum.count(LazyHTML.query(document, ~s(.pb-search-summary a[href="/?scope=all"]))) ==
               1

      refute html =~ "This page is unavailable"
    end

    test "payments rail follows Privy and Base RPC, not a hardcoded off switch", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(data-payments-enabled="false")
      assert html =~ "Payments are not enabled on this deployment"

      previous_privy = Application.get_env(:patchbay, :privy, [])
      previous_rpc = Application.get_env(:patchbay, :base_rpc_url)

      Application.put_env(
        :patchbay,
        :privy,
        Keyword.put(List.wrap(previous_privy), :app_id, "did:privy:test")
      )

      Application.put_env(:patchbay, :base_rpc_url, "https://example.com/rpc")

      try do
        enabled = conn |> get(~p"/") |> html_response(200)
        assert enabled =~ ~s(data-payments-enabled="true")
        assert enabled =~ "Wallet not connected — Ask your human to sign in"
        refute enabled =~ "Payments are not enabled on this deployment"
      after
        Application.put_env(:patchbay, :privy, previous_privy)
        Application.put_env(:patchbay, :base_rpc_url, previous_rpc)
      end
    end
  end

  describe "GET /sites" do
    test "shows the researched directory, not an empty board", %{conn: conn} do
      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ ~s(class="pb-dir-grid")
      assert body =~ ~s(href="/sites/chrome")
      assert body =~ ~s(href="/sites/patchbay")
      refute body =~ "Nothing has been reported yet"
      refute body =~ ~s(href="/sites/patchbay.help")
    end

    test "carries Patchbay's own tool as soon as a repair room offers it", %{conn: conn} do
      Rooms.create_seeded_room!("room-one")

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ ~s(href="/sites/patchbay")
      assert body =~ "1 tool"
      assert body =~ "0 agent posts"
    end

    test "carries the contract a repair room is currently offering", %{conn: conn} do
      room = Rooms.create_seeded_room!("room-one")
      [v1] = Rooms.list_tool_revisions!(query: [filter: [room_id: room.id]])
      Rooms.retire_tool_revision!(v1)

      room.id
      |> Fixtures.revision_attributes()
      |> Map.delete(:contract_sha256)
      |> Map.merge(%{
        generation: 2,
        name: "uplift_current_skill_v2",
        parent_revision_id: v1.id,
        description: "Improve the Skill and say what changed."
      })
      |> Rooms.create_tool_revision!()

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ "patchbay.help"
      assert body =~ "2 tools"
      assert body =~ "0 agent posts"

      site_page = conn |> get(~p"/sites/patchbay.help") |> html_response(200)

      assert site_page =~ "uplift_current_skill_v1"
      assert site_page =~ "uplift_current_skill_v2"

      tool_page =
        conn |> get(~p"/sites/patchbay.help/tools/uplift_current_skill_v2") |> html_response(200)

      assert tool_page =~ "1 version shown, newest first"
      assert tool_page =~ "Improve the Skill and say what changed."
    end

    test "marks Patchbay's own card on the directory grid", %{conn: conn} do
      Rooms.create_seeded_room!("room-one")

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ ~s(class="pb-dir-card is-ours")
      assert body =~ "Official supporter"
      assert body =~ "Exposes tools"
    end
  end

  describe "GET /sites/:origin" do
    test "lists the site's posts before its tools", %{conn: conn} do
      site = site!("shopify.com")
      first = tool!(site, %{title: "Start checkout"})
      second = tool!(site, %{contract_sha256: @other_contract})
      tool!(site, %{name: "search", contract_sha256: @other_contract})

      report!(first)
      report!(second, %{verdict: :verified_failure})
      report!(second, %{verdict: :errored})

      body = conn |> get(~p"/sites/shopify.com") |> html_response(200)

      assert body =~ "checkout"
      assert body =~ "search"
      assert body =~ ~s(href="/sites/shopify/tools/checkout")
      assert body =~ ~s(href="/sites/shopify/tools/search")
      assert body =~ ~s(id="pb-site-tools")
      assert body =~ ~s(id="pb-site-posts")
      {tools_at, _} = :binary.match(body, ~s(id="pb-site-tools"))
      {posts_at, _} = :binary.match(body, ~s(id="pb-site-posts"))
      assert posts_at < tools_at
    end

    test "the ask page and the open-questions and priority feeds render", %{conn: conn} do
      site = site!("shop.example")
      tool = tool!(site, %{name: "checkout"})
      report!(tool, %{note: "the cart stayed empty"})

      assert conn |> get(~p"/ask") |> html_response(200) =~ "Ask a question"
      assert conn |> get(~p"/questions") |> html_response(200) =~ "Open questions"
      assert conn |> get(~p"/priority") |> html_response(200) =~ "Paid priority"
    end

    test "a site page lists a question that names no tool", %{conn: conn} do
      site = site!("helpme.example")

      Forum.ask_question!(%{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: "How do I export my data from this site?",
        body_markdown: "Looking for an export flow."
      })

      body = conn |> get(~p"/sites/helpme.example") |> html_response(200)
      assert body =~ "How do I export my data from this site?"
      assert body =~ ~s(href="/posts/)
    end

    test "says so plainly when a site has nothing on it yet", %{conn: conn} do
      site!("quiet.example")

      body = conn |> get(~p"/sites/quiet.example") |> html_response(200)

      assert body =~
               "No public WebMCP tool inventory has been verified for this entry. Discussions about the company appear above."

      assert body =~ "Nothing has been asked or reported about this site yet."
    end

    test "presents a tool's copy on the tool row", %{conn: conn} do
      site = site!("shopify.com")
      tool!(site, %{title: "Start checkout", description: "Puts the cart through."})

      body = conn |> get(~p"/sites/shopify.com") |> html_response(200)

      assert body =~ "checkout"
      assert body =~ "Puts the cart through."
    end

    test "renders the address exactly as it is stored", %{conn: conn} do
      site!("xn--80ak6aa92e.com")

      body = conn |> get(~p"/sites/xn--80ak6aa92e.com") |> html_response(200)

      assert body =~ "xn--80ak6aa92e.com"
    end

    test "normalizes the address it was asked for", %{conn: conn} do
      site!("shopify.com")

      assert conn |> get(~p"/sites/Shopify.com") |> html_response(200) =~ "shopify.com"
      assert conn |> get(~p"/sites/shopify.com.") |> html_response(200) =~ "shopify.com"
    end

    test "a site that is not on the board is not found", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, ~p"/sites/nope.example") end)
      assert_error_sent(404, fn -> get(conn, ~p"/sites/not a host!") end)
    end
  end

  describe "GET /sites/:origin/tools/:name" do
    test "lists every version newest first with its reports and replies", %{conn: conn} do
      site = site!("shopify.com")
      older = tool!(site)
      newer = tool!(site, %{contract_sha256: @other_contract})

      report!(older, %{note: "the old contract worked"})
      first = report!(newer, %{note: "first thing I tried", verdict: :verified_failure})
      report!(newer, %{note: "second thing I tried"})

      reply!(first, %{verdict: :verified_failure, note: "I saw the same thing"})

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "2 versions shown, newest first"

      assert :binary.match(body, "second thing I tried") <
               :binary.match(body, "first thing I tried")

      assert :binary.match(body, String.slice(@other_contract, 0, 12)) <
               :binary.match(body, String.slice(@contract, 0, 12))

      assert body =~ "I saw the same thing"
      assert body =~ "Did not work"
    end

    test "counts each version's verdicts and its claimed reporters", %{conn: conn} do
      site = site!("shopify.com")
      first = tool!(site)
      second = tool!(site, %{contract_sha256: @other_contract})

      report!(first)
      report!(second, %{verdict: :verified_failure})
      report!(second, %{verdict: :errored})

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "1 worked · 0 did not · 0 errored · 0 unclear"
      assert body =~ "0 worked · 1 did not · 1 errored · 0 unclear"
      assert body =~ "2 claimed reporters (nothing here is verified)"
    end

    test "says what changed in the words between two versions", %{conn: conn} do
      site = site!("shopify.com")

      tool!(site, %{
        title: "Start checkout",
        description: "Puts the cart through. It needs a postal address."
      })

      tool!(site, %{
        contract_sha256: @other_contract,
        title: "Begin checkout",
        description: "Puts the cart through. It needs a card on file."
      })

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "WHAT CHANGED"
      assert body =~ ~s(<s>Start checkout</s>)
      assert body =~ ~s(<ins>Begin checkout</ins>)

      assert body =~ "pb-sentence is-added"
      assert body =~ "It needs a card on file."
      assert body =~ "pb-sentence is-removed"
      assert body =~ "It needs a postal address."
      assert body =~ "pb-sentence is-kept"
      assert body =~ "Puts the cart through."

      # The oldest version on the page has nothing behind it to read against.
      assert body =~ "This is the earliest version of this tool the board has"
    end

    test "says so when only the shape of a version changed", %{conn: conn} do
      site = site!("shopify.com")
      tool!(site, %{title: "Start checkout", description: "Puts the cart through."})

      tool!(site, %{
        contract_sha256: @other_contract,
        title: "Start checkout",
        description: "Puts the cart through."
      })

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "The words did not change."
      refute body =~ "pb-sentence is-added"
    end

    test "says plainly when a version has no reports on it", %{conn: conn} do
      "shopify.com" |> site!() |> tool!()

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "No agent has reported on this version yet."
    end

    test "marks Patchbay's own answer in a thread", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!(%{verdict: :verified_failure})

      Forum.add_operator_reply!(
        %{
          report_id: report.id,
          verdict: :verified_failure,
          note: "We have replaced the tool."
        },
        authorize?: false
      )

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "patchbay-nameplate-agent"
      assert body =~ "Patchbay Agent"
      assert body =~ "We have replaced the tool."
    end

    test "shows only the newest reports and says how many there are", %{conn: conn} do
      tool = "shopify.com" |> site!() |> tool!()

      Enum.each(1..12, fn n -> report!(tool, %{note: "attempt #{n}"}) end)

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "attempt 12"
      assert body =~ "attempt 1"
      assert body =~ "Showing the newest 10 of 12 reports"
    end

    test "shows only the first replies to a busy report", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      Enum.each(1..12, fn n -> reply!(report, %{note: "reply #{n}"}) end)

      body = conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200)

      assert body =~ "reply 1"
      refute body =~ "reply 11"
      assert conn |> get(~p"/reports/#{report.id}") |> html_response(200) =~ "reply 11"
    end

    test "a tool that is not on the board is not found", %{conn: conn} do
      site!("shopify.com")

      assert_error_sent(404, fn -> get(conn, ~p"/sites/shopify.com/tools/checkout") end)
    end

    test "an address that could never name a tool is not found", %{conn: conn} do
      site!("shopify.com")

      for name <- ["\u0000", "a\u0000b", "Checkout", String.duplicate("a", 65)] do
        assert_error_sent(404, fn ->
          get(conn, "/sites/shopify.com/tools/" <> URI.encode(name, &URI.char_unreserved?/1))
        end)
      end
    end
  end

  describe "GET /reports/:id reply pages" do
    # Notes are numbered so the order a page shows can be read back off it.
    defp numbered_replies!(report, range) do
      for n <- range, do: reply!(report, %{note: "reply-#{String.pad_leading("#{n}", 3, "0")}"})
    end

    # Ties in the time of writing fall back on the id, on the page and in the API alike.
    defp written_at_once!(replies) do
      for reply <- replies do
        Patchbay.Repo.query!("UPDATE forum_replies SET inserted_at = $1 WHERE id = $2", [
          ~U[2026-01-01 00:00:00.000000Z],
          Ecto.UUID.dump!(reply.id)
        ])
      end
    end

    defp notes_shown(body) do
      body
      |> LazyHTML.from_document()
      |> LazyHTML.query(".patchbay-reply-list .patchbay-board-text")
      |> LazyHTML.text()
      |> then(&Regex.scan(~r/reply-\d{3}/, &1))
      |> List.flatten()
    end

    defp next_page_path(body) do
      case Regex.run(~r/href="(\/reports\/[^"#]*after=[^"#]*)#patchbay-replies"/, body) do
        [_whole, path] -> path |> String.replace("&amp;", "&")
        nil -> nil
      end
    end

    # Every reply a person reads walking the thread from its start, page by page.
    defp human_walk(conn, path, seen \\ []) do
      body = conn |> get(path) |> html_response(200)
      notes = seen ++ notes_shown(body)

      case next_page_path(body) do
        nil -> notes
        next -> human_walk(conn, next, notes)
      end
    end

    defp api_walk(conn, report_id, cursor \\ nil, seen \\ []) do
      params = if cursor, do: %{"after" => cursor}, else: %{}
      page = conn |> get("/forum/reports/#{report_id}", params) |> json_response(200)
      notes = seen ++ Enum.map(page["replies"], & &1["quoted_note"])

      case page["pagination"] do
        %{"has_more" => true, "next_cursor" => next} -> api_walk(conn, report_id, next, notes)
        _last -> notes
      end
    end

    defp signed_in(conn, profile) do
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(PatchbayWeb.Plugs.CurrentProfile.session_key(), profile.id)
    end

    defp person!(subject) do
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:" <> subject,
        wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
      })
    end

    test "walks every reply in the order the API reads them, whichever handed out the continuation",
         %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      {tied, later} = report |> numbered_replies!(1..250) |> Enum.split(150)
      written_at_once!(tied)
      expected = Enum.map(Enum.sort_by(tied, & &1.id) ++ later, & &1.note)

      first = conn |> get(~p"/reports/#{report.id}") |> html_response(200)
      assert notes_shown(first) == Enum.take(expected, 100)
      refute first =~ "Back to first replies"
      refute first =~ "No replies yet"
      second_path = next_page_path(first)
      assert second_path

      # A reply written while someone is reading lands at the end of the thread.
      reply!(report, %{note: "reply-251"})

      assert human_walk(conn, ~p"/reports/#{report.id}") == expected ++ ["reply-251"]
      assert api_walk(conn, report.id) == expected ++ ["reply-251"]

      # A machine continuation opens the same place on the page.
      api_first = conn |> get("/forum/reports/#{report.id}") |> json_response(200)
      api_cursor = api_first["pagination"]["next_cursor"]

      after_machine =
        conn |> get(~p"/reports/#{report.id}?after=#{api_cursor}") |> html_response(200)

      assert notes_shown(after_machine) == Enum.slice(expected, 20, 100)
      assert after_machine =~ "Back to first replies"

      # And the page's continuation reads on through the API.
      %{"after" => page_cursor} = URI.decode_query(URI.parse(second_path).query)

      api_after_page =
        conn
        |> get("/forum/reports/#{report.id}", %{"after" => page_cursor})
        |> json_response(200)

      assert Enum.map(api_after_page["replies"], & &1["quoted_note"]) ==
               Enum.slice(expected, 100, 20)
    end

    test "refuses a continuation this report never handed out, with a way back", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      other = "other.example" |> site!() |> tool!() |> report!()
      numbered_replies!(report, 1..101)
      numbered_replies!(other, 1..101)

      other_cursor =
        other
        |> then(&get(conn, ~p"/reports/#{&1.id}"))
        |> html_response(200)
        |> next_page_path()
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("after")

      <<first_byte, rest::binary>> = other_cursor
      tampered = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      for bad <- ["", "not-a-cursor", tampered, other_cursor, String.duplicate("a", 2049)] do
        body = conn |> get(~p"/reports/#{report.id}", %{"after" => bad}) |> html_response(400)

        assert body =~ "This reply link has expired or is invalid."
        assert body =~ ~s(href="/reports/#{report.id}#patchbay-replies")
        refute body =~ "No replies yet"
        refute body =~ "reply-001"
      end

      assert_error_sent(404, fn ->
        get(conn, ~p"/reports/#{Ash.UUID.generate()}", %{"after" => other_cursor})
      end)
    end

    test "a continuation that can no longer be followed says so and offers a retry, not an empty thread",
         %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      numbered_replies!(report, 1..3)
      unreadable = PatchbayWeb.Forum.ReplyCursor.sign(report.id, "not a place in the thread")

      response = get(conn, ~p"/reports/#{report.id}?after=#{unreadable}")
      body = html_response(response, 503)

      assert body =~ "could not be loaded right now"
      assert body =~ ~s(href="#{response.request_path}?#{response.query_string}")
      assert body =~ ~s(href="/reports/#{report.id}#patchbay-replies")
      refute body =~ "No replies yet"
    end

    test "a page past the last reply does not call the thread empty", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      [only] = numbered_replies!(report, 1..1)

      %{results: [placed]} =
        Forum.list_replies_for_report!(report.id,
          page: [limit: 1],
          query: [filter: [id: only.id]]
        )

      past_end = PatchbayWeb.Forum.ReplyCursor.sign(report.id, placed.__metadata__.keyset)
      body = conn |> get(~p"/reports/#{report.id}?after=#{past_end}") |> html_response(200)

      refute body =~ "No replies yet"
      assert body =~ "No replies past this point."
      assert body =~ "Back to first replies"
      refute body =~ "More replies"
    end

    test "a reply posted from a later page lands on the page that ends with it", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      report |> numbered_replies!(1..130) |> written_at_once!()
      conn = signed_in(conn, person!("aaa"))

      second_path =
        conn |> get(~p"/reports/#{report.id}") |> html_response(200) |> next_page_path()

      second = conn |> get(second_path) |> html_response(200)
      %{"after" => cursor} = URI.decode_query(URI.parse(second_path).query)
      assert second =~ ~s(name="after" value="#{cursor}")

      # A refused reply comes back to the page it was written on, draft intact.
      refused =
        conn
        |> post(~p"/reports/#{report.id}/replies", %{
          "after" => cursor,
          "reply" => %{"verdict" => "", "note" => "kept for me"}
        })
        |> html_response(200)

      assert refused =~ "Say whether the tool worked before you post."
      assert refused =~ "kept for me"
      assert notes_shown(refused) == notes_shown(second)

      posted =
        post(conn, ~p"/reports/#{report.id}/replies", %{
          "after" => cursor,
          "reply" => %{"verdict" => "verified_failure", "note" => "my own reply"}
        })

      landing = redirected_to(posted)
      assert landing =~ "#patchbay-replies"
      landing_path = String.replace(landing, "#patchbay-replies", "")
      refute landing_path == "/reports/#{report.id}"

      # The 99 replies before it, in the thread's own order, then the new one.
      expected = api_walk(conn, report.id)
      assert List.last(expected) == "my own reply"
      shown = conn |> get(landing_path) |> html_response(200)
      assert notes_shown(shown) ++ ["my own reply"] == Enum.take(expected, -100)
      refute shown =~ Enum.at(expected, -101)
      assert shown =~ "my own reply"
      refute shown =~ "More replies"

      # A reply that arrives afterwards does not push the person's own off the page.
      reply!(report, %{note: "reply-131"})
      again = conn |> get(landing_path) |> html_response(200)
      assert again =~ "my own reply"
      assert again =~ "More replies"
      refute again =~ "reply-131"
    end

    test "a reply on a short thread lands on its opening page", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      numbered_replies!(report, 1..3)

      posted =
        conn
        |> signed_in(person!("bbb"))
        |> post(~p"/reports/#{report.id}/replies", %{
          "reply" => %{"verdict" => "verified_success", "note" => "worked for me"}
        })

      assert redirected_to(posted) == "/reports/#{report.id}#patchbay-replies"
    end

    # A continuation minted the way the board mints them, dated in the past:
    # more than a day ago it has expired, within the day it is still good.
    defp dated_cursor(report, keyset, seconds_ago) do
      Phoenix.Token.sign(
        PatchbayWeb.Endpoint,
        "report-replies-v1",
        %{report_id: report.id, keyset: keyset},
        signed_at: System.system_time(:second) - seconds_ago
      )
    end

    defp expired_cursor(report, keyset), do: dated_cursor(report, keyset, 86_401)

    defp keyset_of(report, reply) do
      %{results: [placed]} =
        Forum.list_replies_for_report!(report.id,
          page: [limit: 1],
          query: [filter: [id: reply.id]]
        )

      placed.__metadata__.keyset
    end

    test "a continuation from more than a day ago has expired", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      [first | _rest] = numbered_replies!(report, 1..3)
      keyset = keyset_of(report, first)

      body =
        conn
        |> get(~p"/reports/#{report.id}?after=#{expired_cursor(report, keyset)}")
        |> html_response(400)

      assert body =~ "This reply link has expired or is invalid."

      fresh = dated_cursor(report, keyset, 86_000)

      assert conn |> get(~p"/reports/#{report.id}?after=#{fresh}") |> html_response(200) =~
               "reply-002"
    end

    test "a reply refused after its page link expired keeps the draft, on a page that leads back",
         %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      [first | _rest] = numbered_replies!(report, 1..3)
      stale = expired_cursor(report, keyset_of(report, first))

      body =
        conn
        |> signed_in(person!("ccc"))
        |> post(~p"/reports/#{report.id}/replies", %{
          "after" => stale,
          "reply" => %{"verdict" => "", "note" => "kept through the expiry"}
        })
        |> html_response(400)

      assert body =~ "This reply link has expired or is invalid."
      assert body =~ "Say whether the tool worked before you post."
      assert body =~ "kept through the expiry"
      assert body =~ ~s(action="/reports/#{report.id}/replies")
      refute body =~ ~s(name="after")
      assert body =~ ~s(href="/reports/#{report.id}#patchbay-replies")
      refute body =~ ~s(href="/reports/#{report.id}/replies)
      refute body =~ "reply-001"
    end

    test "a reply refused while its page cannot be read keeps the draft and retries by reading",
         %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      numbered_replies!(report, 1..3)
      unreadable = PatchbayWeb.Forum.ReplyCursor.sign(report.id, "not a place in the thread")

      body =
        conn
        |> signed_in(person!("ddd"))
        |> post(~p"/reports/#{report.id}/replies", %{
          "after" => unreadable,
          "reply" => %{"verdict" => "", "note" => "kept through the outage"}
        })
        |> html_response(503)

      assert body =~ "could not be loaded right now"
      assert body =~ "Say whether the tool worked before you post."
      assert body =~ "kept through the outage"
      assert body =~ ~s(name="after" value="#{unreadable}")
      assert body =~ ~s(href="/reports/#{report.id}?after=#{unreadable}")
      refute body =~ ~s(href="/reports/#{report.id}/replies)
      refute body =~ "No replies yet"
    end

    # The page that ends on a saved reply is looked up after the save, so a
    # lookup that cannot find the reply is an error to say, never a crash.
    test "the landing page of a reply that cannot be read back is an error, not a crash" do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      [only] = numbered_replies!(report, 1..1)
      unread = %Forum.Reply{id: Ash.UUID.generate(), report_id: report.id}

      assert PatchbayWeb.Forum.Board.page_ending_at(unread) == {:error, :reply_not_read}
      assert PatchbayWeb.Forum.Board.page_ending_at(only) == {:ok, nil}
    end
  end

  describe "POST /reports/:id/replies" do
    test "a reply not shaped like the form's is refused without a write, keeping what was typed",
         %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()
      conn = signed_in(conn, person!("eee"))

      # The container is not the form's, then one field at a time is not.
      for reply <- [
            "typed straight in",
            ["verified_success"],
            %{"verdict" => %{"x" => "1"}, "note" => "kept beside a bad verdict"},
            %{"verdict" => "verified_success", "note" => %{"x" => "1"}},
            %{"verdict" => "verified_success", "note" => ["a", "b"]}
          ] do
        body =
          conn
          |> post(~p"/reports/#{report.id}/replies", %{"reply" => reply})
          |> html_response(200)

        assert body =~ "That reply could not be posted."
        assert body =~ ~s(action="/reports/#{report.id}/replies")
      end

      assert Forum.list_replies_for_report!(report.id).results == []

      # The string beside a malformed field stays on the form; the malformed
      # field is dropped rather than shown.
      body =
        conn
        |> post(~p"/reports/#{report.id}/replies", %{
          "reply" => %{"verdict" => %{"x" => "1"}, "note" => "kept beside a bad verdict"}
        })
        |> html_response(200)

      document = LazyHTML.from_document(body)

      assert document |> LazyHTML.query("#pb-reply-note") |> LazyHTML.text() =~
               "kept beside a bad verdict"

      assert document
             |> LazyHTML.query("#pb-reply-verdict option[selected]")
             |> LazyHTML.attribute("value") == [""]

      # JSON preserves these types. Ash would coerce boolean/numeric notes to
      # strings, but neither HTTP entry point accepts non-text reply fields.
      api_conn =
        Plug.Conn.put_session(
          conn,
          PatchbayWeb.Plugs.ForumSession.session_key(),
          Ash.UUID.generate()
        )

      for field <- ["verdict", "note"], value <- [%{}, ["text"], true, 42] do
        payload = Map.put(%{"verdict" => "unknown", "note" => "safe"}, field, value)

        assert %{"problem_code" => "invalid"} =
                 api_conn
                 |> put_req_header("content-type", "application/json")
                 |> post("/forum/reports/#{report.id}/replies", Jason.encode!(payload))
                 |> json_response(422)
      end

      assert Forum.list_replies_for_report!(report.id).results == []
    end

    test "a person's replies draw on the same hourly share as the page's tools", %{conn: conn} do
      Application.put_env(:patchbay, :forum_replies_per_hour, 2)
      on_exit(fn -> Application.delete_env(:patchbay, :forum_replies_per_hour) end)

      report = "shopify.com" |> site!() |> tool!() |> report!()
      session_id = Ash.UUID.generate()

      conn =
        conn
        |> signed_in(person!("fff"))
        |> Plug.Conn.put_session(PatchbayWeb.Plugs.ForumSession.session_key(), session_id)

      reply = %{"verdict" => "verified_success", "note" => "worked for me"}

      # One through the page's tools and one from the form, both this browser's.
      assert conn |> post("/forum/reports/#{report.id}/replies", reply) |> json_response(201)

      assert conn
             |> post(~p"/reports/#{report.id}/replies", %{"reply" => reply})
             |> redirected_to() =~ "#patchbay-replies"

      # The third is refused at either door, draft intact, and nothing is written.
      refused =
        conn
        |> post(~p"/reports/#{report.id}/replies", %{
          "reply" => %{"verdict" => "verified_failure", "note" => "kept while waiting"}
        })
        |> html_response(200)

      assert refused =~ "You have already posted 2 replies in the past hour."
      assert refused =~ "kept while waiting"

      assert %{"problem_code" => "rate_limited"} =
               conn |> post("/forum/reports/#{report.id}/replies", reply) |> json_response(429)

      replies = Forum.list_replies_for_report!(report.id).results
      assert Enum.map(replies, & &1.author_kind) == [:agent, :human]
      assert Enum.all?(replies, &(&1.browser_session_id == session_id))

      # Another browser's share is its own.
      other =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(
          PatchbayWeb.Plugs.ForumSession.session_key(),
          Ash.UUID.generate()
        )

      assert other |> post("/forum/reports/#{report.id}/replies", reply) |> json_response(201)
    end
  end

  describe "GET /reports/:id" do
    test "shows one report with what it recorded and its replies", %{conn: conn} do
      report =
        "report.example.invalid"
        |> site!()
        |> tool!()
        |> report!(%{
          note: "the button never changed",
          failure_code: "cart_total_unchanged",
          verdict: :verified_failure,
          handler_result: %{"ok" => true},
          observed: %{"cart_total" => "0.00"}
        })

      reply!(report, %{note: "could not reproduce"})

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "the button never changed"
      assert body =~ "cart_total_unchanged"
      assert body =~ "cart_total"
      assert body =~ "could not reproduce"
      assert body =~ "Did not work"
      assert body =~ "report.example.invalid"
    end

    test "invites a second opinion when nobody has replied", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "No replies yet"
      assert body =~ ~s(id="patchbay-replies")
      assert body =~ "just now"
    end

    test "tells Patchbay's own answer apart from a visitor's", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!(%{verdict: :verified_failure})

      stranger = reply!(report, %{note: "could not reproduce"})

      Forum.add_operator_reply!(
        %{report_id: report.id, verdict: :verified_failure, note: "Fixed."},
        authorize?: false
      )

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "patchbay-nameplate-agent"
      assert body =~ "Patchbay Agent"
      assert body =~ "Agent " <> String.slice(stranger.browser_session_id, 0, 8)
      assert body =~ "Agent " <> String.slice(report.browser_session_id, 0, 8)
    end

    test "renders agent text as words, never as markup", %{conn: conn} do
      note = "<script>alert('x')</script> and <b>bold</b>"

      report =
        "shopify.com"
        |> site!()
        |> tool!()
        |> report!(%{note: note, observed: %{"page" => "<img src=x onerror=y>"}})

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      refute body =~ "<script>"
      refute body =~ "<img src=x"
      assert body =~ "&lt;script&gt;"
      assert body =~ "&lt;img src=x onerror=y&gt;"
    end

    test "retains complete escaped evidence while the report opens with a short note", %{
      conn: conn
    } do
      note = String.duplicate("A long account. ", 30) <> "last note word"
      observed = String.duplicate("z", 4_000) <> "<script>last evidence word</script>"

      report =
        "shopify.com"
        |> site!()
        |> tool!()
        |> report!(%{note: note, observed: %{"page" => observed}})

      html = conn |> get(~p"/reports/#{report.id}") |> html_response(200)
      document = LazyHTML.from_document(html)
      evidence = document |> LazyHTML.query("#report-evidence") |> LazyHTML.text()
      preview = document |> LazyHTML.query("h1") |> LazyHTML.text()
      assert document |> LazyHTML.query(".pb-thread-prose") |> LazyHTML.text() =~ note
      assert evidence =~ observed
      assert evidence =~ @contract
      assert evidence =~ @arguments
      assert evidence =~ DateTime.to_iso8601(report.inserted_at)
      refute preview =~ "last note word"
      assert Enum.empty?(LazyHTML.query(document, "#report-evidence[open]"))
      assert Enum.empty?(LazyHTML.query(document, "#report-evidence script"))
    end

    test "a report that is not on the board is not found", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, ~p"/reports/#{Ash.UUID.generate()}") end)
      assert_error_sent(404, fn -> get(conn, ~p"/reports/not-an-id") end)
    end
  end

  describe "asking and answering as a person" do
    test "a signed-in person asks a question and lands on it", %{conn: conn} do
      conn = signed_in(conn, person!("aaa"))

      conn =
        post(conn, ~p"/threads", %{
          "thread" => %{
            "site" => "checkout.example",
            "title" => "Where does a declined card go?",
            "body_markdown" => "I tried twice and the cart stayed empty each time.",
            "topic_tags" => "Checkout, Cards"
          }
        })

      [_, id] = Regex.run(~r{/posts/(.+)}, redirected_to(conn))

      thread = Ash.get!(Report, id)
      assert thread.thread_kind == :question
      assert thread.author_profile_id == person!("aaa").id
      assert thread.topic_tags == ["checkout", "cards"]

      assert conn |> recycle() |> get(~p"/posts/#{id}") |> html_response(200) =~
               "Where does a declined card go?"
    end

    test "a visitor is told to sign in, keeping what they typed", %{conn: conn} do
      body =
        conn
        |> post(~p"/threads", %{
          "thread" => %{
            "site" => "checkout.example",
            "title" => "a kept title",
            "body_markdown" => "the question that stays typed"
          }
        })
        |> html_response(200)

      assert body =~ "Sign in at the top of the page to ask"
      assert body =~ "a kept title"
      assert body =~ "the question that stays typed"
      assert Forum.list_recent_reports!().results == []
    end

    test "a signed-in person answers a thread with words, not a verdict", %{conn: conn} do
      site = site!("quiet.example")

      thread =
        Forum.ask_question!(%{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "Is there a gift-wrap option?",
          body_markdown: "I cannot find one anywhere."
        })

      conn = signed_in(conn, person!("bbb"))

      conn =
        post(conn, ~p"/threads/#{thread.id}/replies", %{
          "reply" => %{"body_markdown" => "It is under checkout extras."}
        })

      assert redirected_to(conn) =~ ~r{^/posts/#{thread.id}}
      [reply] = Forum.list_replies_for_report!(thread.id).results
      assert reply.reply_kind == :answer
      assert reply.body_markdown == "It is under checkout extras."
      assert reply.author_kind == :human

      assert conn
             |> recycle()
             |> get(~p"/posts/#{thread.id}")
             |> html_response(200) =~ "It is under checkout extras."
    end
  end

  describe "whether a report was checked" do
    test "a report matched to a real call says so, and shows the call's receipt", %{conn: conn} do
      %{report: report, receipt: receipt} = matched_report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Page record matched"
      assert body =~ receipt
      refute body =~ "not matched to a logged call"
    end

    test "a report nobody could match says that instead", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Patchbay has not matched it to a logged call"
      refute body =~ "Page record matched"
      refute body =~ "Call receipt"
    end

    test "a matched receipt is retained once in the collapsed evidence",
         %{conn: conn} do
      %{report: report, receipt: receipt} = matched_report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      evidence = body |> LazyHTML.from_document() |> LazyHTML.query("#report-evidence")
      assert evidence |> LazyHTML.text() |> String.split(receipt) |> length() == 2
      assert Enum.empty?(LazyHTML.query(evidence, "[open]"))
    end

    test "a report with no receipt has no stub to show", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      refute body =~ "pb-receipt-stub"
    end

    test "the tool's own page marks each report either way", %{conn: conn} do
      %{report: matched, tool: tool} = matched_report!()

      Forum.file_report!(%{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: @arguments,
        verdict: :unknown,
        note: "I heard it was broken."
      })

      body =
        conn
        |> get(~p"/sites/#{tool.site.origin}/tools/#{tool.name}")
        |> html_response(200)

      assert body =~ "Verified against Patchbay"
      assert body =~ "Unverified: not matched to a logged call"
      assert body =~ "I heard it was broken."
      assert body =~ matched.note
    end
  end

  # A report the forum could match: a real call on a real studio, reported by
  # the browser that call was issued to, quoting the receipt it was handed.
  defp matched_report!(reporter \\ Ash.UUID.generate()) do
    room = Rooms.create_seeded_room!("room-#{System.unique_integer([:positive])}")

    revision =
      Rooms.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired], limit: 1])
      |> List.first()

    browser_session =
      Rooms.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        forum_session_id: reporter,
        user_agent_digest: Patchbay.Patchbay.Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    invocation =
      Patchbay.Patchbay.InvocationRunner.invoke!(
        room,
        browser_session,
        revision,
        %{"instructions" => "warmer"},
        request_uuid: Ash.UUID.generate(),
        fallback: true
      )

    site = site!(Patchbay.Forum.RoomMirror.origin())

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        name: revision.name,
        contract_sha256: revision.contract_sha256
      })

    report =
      report!(tool, %{
        browser_session_id: reporter,
        verdict: :verified_failure,
        note: "It reported success and the page never changed.",
        receipt: invocation.receipt
      })

    assert report.verified

    %{report: report, tool: Ash.load!(tool, :site), receipt: invocation.receipt}
  end

  describe "every board page" do
    setup %{conn: conn} do
      site = site!("shopify.com")
      report = site |> tool!(%{title: "Start checkout"}) |> report!(%{note: "worked first time"})
      reply!(report, %{note: "same here"})

      bodies = [
        conn |> get(~p"/sites") |> html_response(200),
        conn |> get(~p"/sites/shopify.com") |> html_response(200),
        conn |> get(~p"/sites/shopify.com/tools/checkout") |> html_response(200),
        conn |> get(~p"/reports/#{report.id}") |> html_response(200)
      ]

      %{bodies: bodies}
    end

    test "offers the agent starting point", %{bodies: bodies} do
      for body <- bodies do
        assert body =~ ~s(href="/start")
      end
    end

    test "never leaks the vocabulary of the code behind it", %{bodies: bodies} do
      # The board is written for people, so the words the code uses for itself
      # must never reach the page.
      for body <- bodies,
          word <- ~w(LiveView fallback upsert keyset cookie slug session hook server) do
        refute String.contains?(String.downcase(body), String.downcase(word)),
               "#{word} appears in board copy"
      end
    end
  end
end
