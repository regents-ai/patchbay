defmodule PatchbayWeb.Forum.BoardControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Fixtures
  alias PatchbayWeb.Forum.Fingerprint

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

  describe "GET /sites" do
    test "says plainly that nothing has been reported yet", %{conn: conn} do
      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ "Nothing has been reported yet"
      refute body =~ ~s(href="/sites/patchbay.help")
    end

    test "carries Patchbay's own tool as soon as a repair room offers it", %{conn: conn} do
      Rooms.create_seeded_room!("room-one")

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ ~s(href="/sites/patchbay.help")
      assert body =~ "1 observed tool version · 0 agent reports"
      refute body =~ "Nothing has been reported yet"
    end

    test "lists the rest busiest first, with their counts", %{conn: conn} do
      quiet = site!("quiet.example")
      busy = site!("busy.example")

      quiet |> tool!() |> report!()
      busy_tool = tool!(busy)
      report!(busy_tool)
      report!(busy_tool, %{verdict: :errored})
      tool!(busy, %{contract_sha256: @other_contract})

      body = conn |> get(~p"/sites") |> html_response(200)

      assert [busy_at, quiet_at] =
               Enum.map(["busy.example", "quiet.example"], &:binary.match(body, &1))

      assert busy_at < quiet_at
      assert body =~ "2 observed tool versions · 2 agent reports"
      assert body =~ "1 observed tool version · 1 agent report"
    end

    test "puts Patchbay's own site first however busy the others are", %{conn: conn} do
      Rooms.create_seeded_room!("room-one")
      busy = site!("busy.example")
      busy_tool = tool!(busy)
      report!(busy_tool)
      report!(busy_tool, %{verdict: :errored})

      body = conn |> get(~p"/sites") |> html_response(200)

      assert :binary.match(body, ~s(href="/sites/patchbay.help")) <
               :binary.match(body, ~s(href="/sites/busy.example"))
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
      assert body =~ "2 observed tool versions · 0 agent reports"

      site_page = conn |> get(~p"/sites/patchbay.help") |> html_response(200)

      assert site_page =~ "uplift_current_skill_v1"
      assert site_page =~ "uplift_current_skill_v2"

      tool_page =
        conn |> get(~p"/sites/patchbay.help/tools/uplift_current_skill_v2") |> html_response(200)

      assert tool_page =~ "1 version, newest first"
      assert tool_page =~ "Improve the Skill and say what changed."
    end

    test "a card carries its counts, its strip and when it last heard anything", %{conn: conn} do
      tool = "shopify.com" |> site!() |> tool!()

      report!(tool)
      report!(tool)
      report!(tool, %{verdict: :verified_failure})
      report!(tool, %{verdict: :errored})

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ "1 observed tool version · 4 agent reports"
      assert body =~ "2 worked · 1 did not · 1 errored · 0 unclear"
      assert body =~ ~s(<span class="pb-bar-part is-worked" style="width:50.0%")
      assert body =~ ~s(<span class="pb-bar-part is-failed" style="width:25.0%")
      assert body =~ ~s(<span class="pb-bar-part is-errored" style="width:25.0%")
      assert body =~ "None checked against Patchbay"
      assert body =~ "Last report just now"
    end

    test "a card counts the reports Patchbay matched to a call of its own", %{conn: conn} do
      matched_report!()

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ "1 report checked against Patchbay"
    end

    test "marks which card is this site, and offers a card with nothing on it a way in", %{
      conn: conn
    } do
      Rooms.create_seeded_room!("room-one")
      site!("quiet.example")

      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ ~s(<span class="pb-chip is-ours">This site</span>)

      assert body =~
               "No reports yet. This site appears because Patchbay observed a WebMCP tool version here."

      refute body =~ "Last report never"
    end
  end

  describe "GET /sites/:origin" do
    test "groups a site's tools and shows each version's counts", %{conn: conn} do
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
      assert body =~ "2 versions"
      assert body =~ "1 version"

      # One strip for the whole site, and a chip for every version underneath.
      assert body =~ "1 worked · 1 did not · 1 errored · 0 unclear"
      assert body =~ String.slice(@contract, 0, 12)
      assert body =~ String.slice(@other_contract, 0, 12)
      assert body =~ "Current"
      assert body =~ "First seen just now"
      assert body =~ "2 reports"
      assert body =~ "1 report"
    end

    test "draws every version's fingerprint as colour beside its characters", %{conn: conn} do
      site = site!("shopify.com")
      tool!(site)

      body = conn |> get(~p"/sites/shopify.com") |> html_response(200)

      # Four swatches, the opening characters, the whole digest to hover over,
      # and the colours named for a reader who cannot see them.
      assert body |> String.split(~s(class="pb-fingerprint-chip")) |> length() == 5
      assert body =~ String.slice(@contract, 0, 12)
      assert body =~ ~s(title="#{@contract}")
      assert body =~ "Fingerprint colours: "

      for chip <- Fingerprint.chips(@contract), do: assert(body =~ "background:#{chip.color}")
    end

    test "marks the version a site is on now", %{conn: conn} do
      site = site!("shopify.com")
      tool!(site)
      tool!(site, %{contract_sha256: @other_contract})

      body = conn |> get(~p"/sites/shopify.com") |> html_response(200)

      # The newest version leads its tool and is the only one marked current.
      assert :binary.match(body, String.slice(@other_contract, 0, 12)) <
               :binary.match(body, String.slice(@contract, 0, 12))

      assert body |> String.split(~s(class="pb-chip is-current")) |> length() == 2
    end

    test "says so plainly when a site has nothing on it yet", %{conn: conn} do
      site!("quiet.example")

      body = conn |> get(~p"/sites/quiet.example") |> html_response(200)

      assert body =~ "No tool on this site has been reported on yet."
      assert body =~ "The first agent to call one and write down what happened"
    end

    test "presents a tool's copy as what an agent reported", %{conn: conn} do
      site = site!("shopify.com")
      tool!(site, %{title: "Start checkout", description: "Puts the cart through."})

      body = conn |> get(~p"/sites/shopify.com") |> html_response(200)

      assert body =~ "HOW AN AGENT DESCRIBED THIS VERSION"
      assert body =~ "Start checkout"
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

      assert body =~ "2 versions, newest first"

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
      refute body =~ "attempt 1<"
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

  describe "GET /reports/:id" do
    test "shows one report with what it recorded and its replies", %{conn: conn} do
      report =
        "shopify.com"
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
      assert body =~ "shopify.com"
    end

    test "invites a second opinion when nobody has replied", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Nobody has replied to this report yet."
      assert body =~ "can say whether it saw the same thing"
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

    test "shortens a long record and says so", %{conn: conn} do
      report =
        "shopify.com"
        |> site!()
        |> tool!()
        |> report!(%{observed: %{"page" => String.duplicate("z", 4_000)}})

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Shortened for display"
      refute body =~ String.duplicate("z", 2_100)
    end

    test "a report that is not on the board is not found", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, ~p"/reports/#{Ash.UUID.generate()}") end)
      assert_error_sent(404, fn -> get(conn, ~p"/reports/not-an-id") end)
    end
  end

  describe "whether a report was checked" do
    test "a report matched to a real call says so, and shows the call's receipt", %{conn: conn} do
      %{report: report, receipt: receipt} = matched_report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Verified against Patchbay"
      assert body =~ receipt
      refute body =~ "not matched to a logged call"
    end

    test "a report nobody could match says that instead", %{conn: conn} do
      report = "shopify.com" |> site!() |> tool!() |> report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body =~ "Unverified: not matched to a logged call"
      refute body =~ "Verified against Patchbay"
      refute body =~ "Call receipt"
    end

    test "a receipt is set out as the stub it is, and nothing else on the page is",
         %{conn: conn} do
      %{report: report, receipt: receipt} = matched_report!()

      body = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert body |> String.split(~s(class="pb-receipt-stub")) |> length() == 2
      assert body =~ ~s(<code class="pb-receipt-value">#{receipt}</code>)

      # The stub carries the checked line, so the page does not say it twice.
      assert body |> String.split("Verified against Patchbay's own record") |> length() == 2
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

    test "offers a way into a repair room", %{bodies: bodies} do
      for body <- bodies do
        assert body =~ ~s(<a class="patchbay-room-link" href="/">Open your own repair room</a>)
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
