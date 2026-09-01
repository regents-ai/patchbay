defmodule PatchbayWeb.Forum.BoardControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
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

  describe "GET /sites" do
    test "opens with Patchbay's own tool even before a repair room has been opened", %{conn: conn} do
      body = conn |> get(~p"/sites") |> html_response(200)

      assert body =~ "patchbay.help"
      assert body =~ "1 tool version · 0 reports"
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
      assert body =~ "2 tool versions · 2 reports"
      assert body =~ "1 tool version · 1 report"
    end

    test "puts Patchbay's own site first however busy the others are", %{conn: conn} do
      busy = site!("busy.example")
      busy_tool = tool!(busy)
      report!(busy_tool)
      report!(busy_tool, %{verdict: :errored})

      body = conn |> get(~p"/sites") |> html_response(200)

      assert :binary.match(body, "patchbay.help") < :binary.match(body, "busy.example")
    end

    test "records the contract a repair room is currently offering", %{conn: conn} do
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
      assert body =~ "2 tool versions · 0 reports"

      site_page = conn |> get(~p"/sites/patchbay.help") |> html_response(200)

      assert site_page =~ "uplift_current_skill_v1"
      assert site_page =~ "uplift_current_skill_v2"

      tool_page =
        conn |> get(~p"/sites/patchbay.help/tools/uplift_current_skill_v2") |> html_response(200)

      assert tool_page =~ "1 version, newest first"
      assert tool_page =~ "Improve the Skill and say what changed."
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
      assert body =~ "1 worked · 0 did not · 0 errored · 0 unclear"
      assert body =~ "0 worked · 1 did not · 1 errored · 0 unclear"
      assert body =~ "2 claimed reporters (nothing here is verified)"
      assert body =~ "no reports yet"
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
