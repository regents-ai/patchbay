defmodule PatchbayWeb.ForumAPI.AgentOffersTest do
  # Agent Offers after a new post: each position is filled on its own from
  # the site's slot of that number or Global's, only copy that may be shown
  # is returned, a repeated post carries none, and the forum result always
  # comes first.
  #
  # Global's three slots are shared by every test, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures
  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Offers

  # Each test comes from an address of its own, so the reports one test files
  # never draw on another's share.
  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    origin = "offers-#{n}.example"
    {:ok, site} = Forum.register_site(origin, authorize?: false)

    %{
      conn: %{
        conn
        | remote_ip: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
      },
      origin: origin,
      site: Offers.open_site_market!(site.id, authorize?: false),
      global: Offers.global_market!(),
      owner: advertiser()
    }
  end

  test "each position is the site's slot, else Global's of the same number, never moved",
       %{conn: conn, origin: origin, site: site, global: global, owner: owner} do
    place(site, 3, approved_version(owner, "Site three", site))
    place(global, 1, approved_version(owner, "Global one", global))
    place(global, 3, approved_version(owner, "Global three", global))

    posted = ask(conn, origin)
    body = json_response(posted, 201)

    assert %{"items" => items} = offers = body["agent_offers"]
    assert offers["disclosure_version"] == "agent-offers-v1"
    assert offers["disclosure"] =~ "Eligible responses for #{origin}"

    assert Enum.map(items, &{&1["position"], &1["label"], &1["text"]}) == [
             {1, "Global · Slot 1", "Global one"},
             {3, "Site · Slot 3", "Site three"}
           ]

    # The forum result comes first, the Offers after it.
    {result_at, _} = :binary.match(posted.resp_body, ~s("thread_id"))
    {offers_at, _} = :binary.match(posted.resp_body, ~s("agent_offers"))
    assert result_at < offers_at

    delivery = Ash.get!(Offers.Delivery, offers["delivery_id"], authorize?: false)
    assert delivery.global_opportunities == [1, 2]
  end

  test "blocked, expired, stale or other-market copy is not shown, and Global stands in",
       %{conn: conn, origin: origin, site: site, global: global, owner: owner} do
    {:ok, other_site} = Forum.register_site("elsewhere-offers.example", authorize?: false)
    other = Offers.open_site_market!(other_site.id, authorize?: false)

    blocked = approved_version(owner, "Blocked", site)
    place(site, 1, blocked)

    block(blocked, moderator())

    place(site, 2, approved_version(owner, "Ran out", site),
      starts_at: DateTime.add(DateTime.utc_now(), -73, :hour)
    )

    place(site, 3, approved_version(owner, "Suits another site", other))

    place(global, 1, approved_version(owner, "Global one", global))

    place(
      global,
      2,
      approved_version(owner, "Stale", global,
        fresh_until: DateTime.add(DateTime.utc_now(), -1, :minute)
      )
    )

    place(global, 3, approved_version(owner, "Global three", global))

    items = conn |> ask(origin) |> json_response(201) |> get_in(["agent_offers", "items"])

    assert Enum.map(items, &{&1["label"], &1["text"]}) == [
             {"Global · Slot 1", "Global one"},
             {"Global · Slot 3", "Global three"}
           ]
  end

  test "a post with nothing showing has no Offers section, and a repeat never has one",
       %{conn: conn, origin: origin, global: global, owner: owner} do
    first = ask(conn, origin, %{"client_request_id" => "same-question"})
    refute Map.has_key?(json_response(first, 201), "agent_offers")

    place(global, 2, approved_version(owner, "Global two", global))

    repeated = ask(first, origin, %{"client_request_id" => "same-question"})
    body = json_response(repeated, 200)
    assert body["repeated"] == true
    refute Map.has_key?(body, "agent_offers")

    replied =
      repeated
      |> again()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/forum/threads/#{body["thread_id"]}/replies",
        Jason.encode!(%{"body_markdown" => "Here is what worked for me."})
      )

    assert [%{"label" => "Global · Slot 2"}] =
             replied |> json_response(201) |> get_in(["agent_offers", "items"])
  end

  @tag :capture_log
  test "a failure choosing Offers leaves them out and changes nothing else" do
    assert Offers.Serving.after_post(%{
             site_id: Ecto.UUID.generate(),
             report_id: Ecto.UUID.generate(),
             reply_id: nil,
             operation: :thread,
             surface: :http_api
           }) == nil
  end

  describe "reporting an Offer" do
    test "names an Offer Patchbay showed, once per reporter, with a bounded note",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      other = approved_version(owner, "Not shown", global)
      posted = ask(conn, origin)

      %{"delivery_id" => delivery_id, "items" => [item]} =
        json_response(posted, 201)["agent_offers"]

      offer = %{
        "placement_id" => item["placement_id"],
        "creative_version_id" => item["creative_version_id"],
        "delivery_id" => delivery_id,
        "reason" => "misleading",
        "note" => "Claims Patchbay endorses it."
      }

      first = posted |> report_offer(offer) |> json_response(201)
      assert %{"reported" => true, "reason" => "misleading", "status" => "open"} = first

      # Again, for another reason: the first report answers, and nothing is added.
      again = posted |> report_offer(%{offer | "reason" => "other"}) |> json_response(201)
      assert again["report_id"] == first["report_id"]
      assert again["reason"] == "misleading"
      assert [_one] = Ash.read!(Offers.OfferReport, authorize?: false)

      # Wording the placement never ran, a response that never carried it, and
      # an overlong note are each refused.
      for {refused, detail} <- [
            {%{offer | "creative_version_id" => other.id}, "placement_id: is not an Offer"},
            {%{offer | "delivery_id" => Ecto.UUID.generate()}, "delivery_id: did not carry"},
            {%{offer | "note" => String.duplicate("é", 2_001)}, "note: is longer than 2,000"}
          ] do
        assert %{"error" => %{"code" => "invalid", "details" => [^detail <> _]}} =
                 posted |> report_offer(refused) |> json_response(422)
      end
    end

    test "a reporter's eleventh report in an hour is refused, from a new session too",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      posted = ask(conn, origin)
      %{"items" => [item]} = json_response(posted, 201)["agent_offers"]

      offer = %{
        "placement_id" => item["placement_id"],
        "creative_version_id" => item["creative_version_id"],
        "reason" => "other"
      }

      for _ <- 1..10, do: assert(json_response(report_offer(posted, offer), 201))

      assert %{"error" => %{"code" => "rate_limited"}} =
               posted |> report_offer(offer) |> json_response(429)

      # A new session costs nothing, so the address it comes from is counted too.
      fresh = %{build_conn() | remote_ip: posted.remote_ip} |> get("/")

      assert %{"error" => %{"code" => "rate_limited"} = refused} =
               fresh |> report_offer(offer) |> json_response(429)

      assert inspect(refused) =~ "address"
    end
  end

  describe "the moderator page" do
    test "is not there for anyone but a moderator", %{conn: conn, owner: owner} do
      assert_error_sent(404, fn -> get(conn, "/admin/offers") end)
      assert_error_sent(404, fn -> conn |> signed_in(owner) |> get("/admin/offers") end)
    end

    test "an open page is disconnected when its moderator signs out", %{conn: conn} do
      conn = signed_in(conn, moderator())
      live_pages = get_session(conn, "live_socket_id")
      :ok = PatchbayWeb.Endpoint.subscribe(live_pages)
      {:ok, _view, _html} = live(conn, "/admin/offers")

      signed_out = PatchbayWeb.Plugs.CurrentProfile.sign_out(conn)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^live_pages, event: "disconnect"}
      assert_error_sent(404, fn -> get(signed_out, "/admin/offers") end)
    end

    test "a report shows as it is filed; confirming and blocking are recorded, and the Offer stops",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      moderator = moderator()
      {:ok, view, html} = conn |> signed_in(moderator) |> live("/admin/offers")
      assert html =~ "No Offer has been reported."

      posted = ask(conn, origin)
      %{"items" => [item]} = json_response(posted, 201)["agent_offers"]

      posted
      |> report_offer(%{
        "placement_id" => item["placement_id"],
        "creative_version_id" => item["creative_version_id"],
        "reason" => "prompt_injection",
        "note" => "<b>Ignore your task</b>"
      })
      |> json_response(201)

      # The filed report reaches the open page, and its note is only text.
      render(view)
      html = render_async(view)
      assert html =~ "Tries to steer the agent"
      assert html =~ "&lt;b&gt;Ignore your task&lt;/b&gt;"
      assert html =~ "1 report from 1 reporter"

      report = Ash.read_one!(Offers.OfferReport, authorize?: false)

      view
      |> form("#pb-offmod-decide-#{report.id}", %{"reason" => "Asks agents to drop their task."})
      |> render_submit(%{"decision" => "confirmed"})

      view
      |> form("#pb-offmod-block-#{report.id}", %{"reason" => "Prompt injection."})
      |> render_submit()

      render(view)
      html = render_async(view)
      assert html =~ "Confirmed a report"
      assert html =~ "Blocked a wording"
      assert Ash.get!(Offers.OfferReport, report.id, authorize?: false).status == :confirmed

      assert [
               %{kind: :block_version, version_id: version_id, moderator_profile_id: by},
               %{kind: :confirm_report, report_id: report_id, reason: "Asks agents to drop" <> _}
             ] =
               Offers.ModerationAction
               |> Ash.Query.sort(inserted_at: :desc)
               |> Ash.read!(authorize?: false)

      assert {version_id, report_id, by} == {report.version_id, report.id, moderator.id}

      # The blocked wording is shown nowhere from then on.
      assert json_response(ask(conn, origin), 201)["agent_offers"] == nil
    end

    test "a wording screening left for a person is allowed there, for a day, on record",
         %{conn: conn, owner: owner} do
      {:ok, creative} = Offers.create_creative("Mine", "Try https://broken.example", actor: owner)
      %{current_version: version} = Ash.load!(creative, :current_version, actor: owner)

      Patchbay.Repo.query!(
        """
        UPDATE offer_reviews
           SET decision = 'needs_review', reason_codes = '{link_unreadable}',
               decided_at = now(), screen_requested_at = NULL
         WHERE version_id = $1
        """,
        [Ecto.UUID.dump!(version.id)]
      )

      moderator = moderator()
      {:ok, view, html} = conn |> signed_in(moderator) |> live("/admin/offers")
      assert html =~ "A link could not be opened"

      [review] = Ash.read!(Offers.Review, authorize?: false)

      view
      |> form("#pb-offmod-settle-#{review.id}", %{"reason" => "The page opens for me."})
      |> render_submit(%{"decision" => "allow"})

      render(view)
      assert render_async(view) =~ "Nothing is waiting for a person."

      review = Ash.get!(Offers.Review, review.id, authorize?: false)
      assert review.decision == :allow
      assert DateTime.diff(review.fresh_until, DateTime.utc_now(), :hour) in 23..24

      assert [%{kind: :allow_version, review_id: review_id, version_id: version_id}] =
               Ash.read!(Offers.ModerationAction, authorize?: false)

      assert {review_id, version_id} == {review.id, version.id}
    end
  end

  describe "the market list" do
    test "shows each slot's Offer, the least that replaces it, the next leader and the counts",
         %{conn: conn, origin: origin, site: site, global: global, owner: owner} do
      place(site, 1, approved_version(owner, "Site one", site), amount_minor: 1001)
      lead_next(site, 1, approved_version(owner, "Next one", site), 2000)
      place(global, 2, approved_version(owner, "Global two", global))
      ask(conn, origin)

      {:ok, view, html} = live(conn, "/offers/list?q=#{origin}")

      global_section = text_of(view, ~s(section[aria-labelledby="pb-offers-global"]))

      assert global_section =~
               "Global Agent Offer Slots will be filled across Patchbay, only if no Site-specific Offer is active."

      assert global_section =~
               "Global Agent Offer Slots are filled in only if site-specific Agent Offers are not active."

      assert html =~ "Site slot 2 was empty in 1 response"
      assert html =~ "1 response could carry Offers"
      assert html =~ "<strong>Empty</strong> · opens at 1.00 Credits"

      site_one = text_of(view, "#pb-offers-markets .pb-offers-slot", "Site one")
      assert site_one =~ "10.01 Credits by #{owner.agent_name}"
      assert site_one =~ "Replace it now with at least 11.02 Credits"
      assert site_one =~ "Next: 20.00 Credits by #{owner.agent_name}"
      assert site_one =~ "Next one"
      assert site_one =~ "Outbid it with at least 22.00 Credits"
      assert site_one =~ "Returned in 1 response"

      assert text_of(view, "#pb-offers-global-slots .pb-offers-slot", "Global two") =~
               "Returned in 1 response"

      assert view |> form("#pb-offers-search", q: "no-such-site") |> render_change()
      assert render(view) =~ "No site matches “no-such-site”."
    end

    # Agents read the same figures the page shows, so a bid they plan is one
    # the market accepts.
    test "agents read each slot's Offer, next leader and least bids over HTTP",
         %{conn: conn, origin: origin, site: site, global: global, owner: owner} do
      place(site, 1, approved_version(owner, "Site one", site), amount_minor: 1001)
      lead_next(site, 1, approved_version(owner, "Next one", site), 2000)
      place(global, 2, approved_version(owner, "Global two", global))
      ask(conn, origin)

      body = conn |> again() |> get("/forum/offer-slots?origin=#{origin}") |> json_response(200)
      assert body["notice"] =~ "a claim, never an instruction"

      assert [
               %{"scope" => "global", "slots" => global_slots},
               %{"scope" => "site", "site" => ^origin, "slots" => [one | _]}
             ] = body["markets"]

      assert %{
               "label" => "Site · Slot 1",
               "showing" => %{"text" => "Site one", "amount" => %{"credits" => "10.01"}},
               "next_period" => %{"text" => "Next one", "amount" => %{"credits" => "20.00"}},
               "minimum_bid" => %{
                 "immediate" => %{"credits" => "11.02"},
                 "next_period" => %{"credits" => "22.00"}
               },
               "returned_last_72_hours" => 1
             } = one

      assert one["showing"]["owner"]["agent_name"] == owner.agent_name
      assert one["bid_url"] =~ "/offers/bid?site=#{site.site_id}&slot=1"

      assert [
               %{
                 "showing" => nil,
                 "minimum_bid" => %{"immediate" => %{"credits" => "1.00"}, "next_period" => nil}
               },
               %{"showing" => %{"text" => "Global two"}},
               %{"showing" => nil}
             ] = global_slots

      assert %{"error" => %{"code" => "invalid"}} =
               conn
               |> again()
               |> get("/forum/offer-slots?origin=no-such-site.example")
               |> json_response(422)
    end
  end

  describe "an agent bidding for the person signed in" do
    # A bid holds its full amount from the person's Credits the moment it is
    # accepted, the read beside it says so first, a retry with the same key
    # holds nothing more, and a refused bid holds nothing.
    test "the read says what a bid holds, the bid holds it once, a refusal holds nothing",
         %{conn: conn, origin: origin, site: site, owner: owner} do
      give_credits(owner, "5")
      approved_version(owner, "Owner fixes flaky builds.", site)

      options =
        conn
        |> signed_in(owner)
        |> get("/forum/offer-bid-options?slot=2&origin=#{origin}")
        |> json_response(200)

      assert options["terms"]["holds"] =~ "holds its full amount from your Credits"
      assert options["credits"]["available"]["credits"] == "5.00"
      assert [%{"version_id" => version_id, "can_bid_here" => true}] = options["wordings"]

      bid = %{
        slot: 2,
        origin: origin,
        lane: "immediate",
        amount: "2.00",
        version_id: version_id,
        generation: options["slot"]["generation"],
        next_revision: options["slot"]["next_revision"],
        request_key: Ecto.UUID.generate()
      }

      placed = conn |> bid_as(owner, bid) |> json_response(201)
      assert placed["bid"]["amount"]["credits"] == "2.00"
      assert credits(owner) == %{available: "3", held: "2"}

      again = conn |> bid_as(owner, bid) |> json_response(201)
      assert again["bid"]["bid_id"] == placed["bid"]["bid_id"]
      assert credits(owner) == %{available: "3", held: "2"}

      short = %{bid | amount: "10.00", request_key: Ecto.UUID.generate()}

      assert %{"error" => %{"code" => "not_enough_credits", "message" => message}} =
               conn |> bid_as(owner, short) |> json_response(422)

      assert message == "You need 7.00 more Credits."
      assert credits(owner) == %{available: "3", held: "2"}
    end
  end

  describe "the advertiser's own pages" do
    test "active shows what is yours now and then every site showing an Offer",
         %{conn: conn, origin: origin, site: site, owner: owner} do
      place(site, 1, approved_version(owner, "Showing one", site), amount_minor: 1001)
      lead_next(site, 1, approved_version(owner, "Next one", site), 2000)

      {:ok, view, html} = live(signed_in(conn, owner), "/offers/active")

      showing = text_of(view, "#pb-offers-mine-showing-list li", "Showing one")
      assert showing =~ "#{origin} · Slot 1"
      assert showing =~ "10.01 Credits"
      assert showing =~ ~r/you would get back 10\.0[01] Credits/

      next = text_of(view, "#pb-offers-mine-next-list li", "Next one")
      assert next =~ "#{origin} · Slot 1"
      assert next =~ "20.00 Credits"
      assert next =~ "Starts when the current Offer ends"
      assert next =~ "at least 22.00 Credits to take your place"

      ranked = text_of(view, "#pb-offers-ranked-list li", origin)
      assert ranked =~ "Highest bid 10.01 Credits"
      assert ranked =~ "Showing one"

      refute html =~ "Sign in at the top of the page"

      {:ok, _view, signed_out} = live(conn, "/offers/active")
      assert signed_out =~ "Sign in at the top of the page to see your own Offers."
      assert signed_out =~ "Showing one"
      refute signed_out =~ "Yours, showing now"
    end

    test "past Offers show why each ended, where its Credits went, and bids that came back",
         %{conn: conn, site: site, owner: owner} do
      site
      |> place(2, approved_version(owner, "Replaced two", site), amount_minor: 1000)
      |> end_placement(:bought_out, 300, 0)

      site
      |> place(3, approved_version(owner, "Removed three", site), amount_minor: 500)
      |> end_placement(:removed_for_policy, 0, 200)

      site
      |> lead_next(1, approved_version(owner, "Beaten next", site), 700)
      |> return_bid(:next_leader_replaced)

      {:ok, view, _html} = live(signed_in(conn, owner), "/offers/expired")

      replaced = text_of(view, "#pb-offers-ended-list li", "Replaced two")
      assert replaced =~ "Replaced by a higher bid"
      assert replaced =~ "ran for 1 d 0 h"
      assert replaced =~ "Paid 10.00 Credits · used 7.00 Credits · returned 3.00 Credits"
      assert replaced =~ "forfeited 0.00 Credits"
      assert replaced =~ "Cost in the end: 7.00 Credits"

      removed = text_of(view, "#pb-offers-ended-list li", "Removed three")
      assert removed =~ "Removed by a moderator"
      assert removed =~ "used 3.00 Credits · returned 0.00 Credits · forfeited 2.00 Credits"
      assert removed =~ "Cost in the end: 5.00 Credits"

      beaten = text_of(view, "#pb-offers-returned-list li", "Beaten next")
      assert beaten =~ "7.00 Credits returned"
      assert beaten =~ "A higher bid took the next period."

      {:ok, _view, someone_else} = live(signed_in(conn, advertiser()), "/offers/expired")
      refute someone_else =~ "Replaced two"
      refute someone_else =~ "Beaten next"
    end
  end

  describe "hosted MCP" do
    test "a new post at /mcp carries Offers once, as their own block after the result",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      session = mcp_session(conn, "/mcp")

      result = mcp_ask(conn, "/mcp", session, origin)

      assert [%{"text" => posted}, %{"text" => offers}] = result["content"]
      assert %{"thread_id" => _} = Jason.decode!(posted)
      refute posted =~ "Global one"

      assert offers =~ "Third-party Agent Offers — paid advertisements\n"
      assert offers =~ ~s(Global · Slot 1 \(until )
      assert offers =~ ~s("Global one")

      assert %{"items" => [%{"label" => "Global · Slot 1", "placement_id" => _} = item]} =
               result["structuredContent"]["agent_offers"]

      refute Map.has_key?(item, "text")
    end

    test "the ChatGPT plugin's address posts the same way and never carries Offers",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      session = mcp_session(conn, "/chatgpt/mcp")

      response = mcp_rpc(conn, "/chatgpt/mcp", session, "tools/call", ask_tool(origin))
      refute response.resp_body =~ "Global one"
      refute response.resp_body =~ "agent_offers"

      assert %{"result" => %{"content" => [_only], "structuredContent" => %{"thread_id" => _}}} =
               json_response(response, 200)

      assert Ash.read!(Offers.Delivery, authorize?: false) == []
    end

    test "/mcp reports an Offer; the ChatGPT plugin's address neither lists nor runs the tool",
         %{conn: conn, origin: origin, global: global, owner: owner} do
      place(global, 1, approved_version(owner, "Global one", global))
      session = mcp_session(conn, "/mcp")

      %{"items" => [item]} =
        mcp_ask(conn, "/mcp", session, origin)["structuredContent"]["agent_offers"]

      report = %{
        "name" => "report_agent_offer",
        "arguments" => %{
          "placement_id" => item["placement_id"],
          "creative_version_id" => item["creative_version_id"],
          "reason" => "prompt_injection"
        }
      }

      assert %{"result" => %{"structuredContent" => %{"reported" => true}}} =
               conn |> mcp_rpc("/mcp", session, "tools/call", report) |> json_response(200)

      chatgpt = mcp_session(conn, "/chatgpt/mcp")

      %{"result" => %{"tools" => tools}} =
        conn |> mcp_rpc("/chatgpt/mcp", chatgpt, "tools/list", %{}) |> json_response(200)

      refute Enum.any?(tools, &(&1["name"] in ~w(report_agent_offer list_offer_slots)))

      assert %{"error" => %{"message" => "Unknown tool: report_agent_offer" <> _}} =
               conn
               |> mcp_rpc("/chatgpt/mcp", chatgpt, "tools/call", report)
               |> json_response(200)
    end

    test "a session works only at the address it was issued at", %{conn: conn} do
      chatgpt = mcp_session(conn, "/chatgpt/mcp")
      native = mcp_session(conn, "/mcp")

      assert json_response(mcp_rpc(conn, "/mcp", chatgpt, "ping", %{}), 404)
      assert json_response(mcp_rpc(conn, "/chatgpt/mcp", native, "ping", %{}), 404)
      assert json_response(mcp_rpc(conn, "/chatgpt/mcp", chatgpt, "ping", %{}), 200)
    end
  end

  defp mcp_session(conn, path) do
    response = mcp_rpc(conn, path, nil, "initialize", %{"protocolVersion" => "2025-06-18"})
    [session] = get_resp_header(response, "mcp-session-id")
    session
  end

  defp mcp_ask(conn, path, session, origin) do
    %{"result" => result} =
      conn |> mcp_rpc(path, session, "tools/call", ask_tool(origin)) |> json_response(200)

    result
  end

  defp ask_tool(origin) do
    %{
      "name" => "ask_question",
      "arguments" => %{
        "site" => origin,
        "title" => "How do I change a booking here?",
        "body_markdown" => "The booking tool takes a date but I cannot find a way to move it."
      }
    }
  end

  defp mcp_rpc(conn, path, session, method, params) do
    conn = conn |> again() |> put_req_header("content-type", "application/json")
    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    post(conn, path, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  # A slot's words as a reader sees them, markup and line breaks aside.
  defp text_of(view, selector, text \\ nil) do
    view
    |> element(selector, text)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
  end

  defp again(conn), do: %{recycle(conn) | remote_ip: conn.remote_ip}

  defp signed_in(conn, profile) do
    conn
    |> again()
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end

  defp bid_as(conn, profile, bid) do
    conn
    |> signed_in(profile)
    |> put_req_header("content-type", "application/json")
    |> post("/forum/offer-bids", Jason.encode!(bid))
  end

  defp report_offer(posted, offer) do
    posted
    |> again()
    |> put_req_header("content-type", "application/json")
    |> post("/forum/offer-reports", Jason.encode!(offer))
  end

  defp ask(conn, origin, extra \\ %{}) do
    conn
    |> again()
    |> get("/")
    |> again()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/forum/threads",
      Jason.encode!(
        Map.merge(
          %{
            "site" => origin,
            "title" => "How do I change a booking here?",
            "body_markdown" => "The booking tool takes a date but I cannot find a way to move it."
          },
          extra
        )
      )
    )
  end
end
