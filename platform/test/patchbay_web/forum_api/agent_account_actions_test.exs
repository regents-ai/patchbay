defmodule PatchbayWeb.ForumAPI.AgentAccountActionsTest do
  @moduledoc """
  The person's own actions a paired agent takes too (PB-27): reading and
  acknowledging the inbox, Credits help, refreshing a site and deleting an
  Offer. Each door acts
  for the person its signed pairing names, through the action the website
  uses; it refuses an unsigned request and never reaches another account's
  things. Naming the agent is `PatchbayWeb.Forum.NamesTest`'s and the security
  check's; each door's hosted twin is `PatchbayWeb.MCPHostedToolsTest`'s.
  """

  use PatchbayWeb.ConnCase, async: false

  require Ash.Query

  alias Patchbay.CreditsHelp
  alias Patchbay.Forum
  alias Patchbay.Forum.ForumEvent
  alias Patchbay.Forum.Notification
  alias Patchbay.Forum.Principal
  alias Patchbay.Offers
  alias Patchbay.OffersFixtures
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    %{agent: SignedAgent.pair!(), other: SignedAgent.pair!()}
  end

  test "every new door refuses an unsigned request and changes nothing", %{
    conn: conn,
    agent: agent
  } do
    item = notify!(agent.owner)
    site = Forum.register_site!("unsigned-refresh.com")
    check = PatchbayWeb.Forum.SiteChecks.current(site.origin)
    offer = saved_offer!(agent.owner, "Unsigned callers change nothing.")

    for {method, path} <- [
          {:post, "/forum/agent-name"},
          {:post, "/forum/inbox"},
          {:post, "/forum/inbox/#{item.id}/acknowledge"},
          {:post, "/forum/credits-help"},
          {:post, "/forum/credits-help/list"},
          {:get, "/forum/credits-help/#{Ecto.UUID.generate()}"},
          {:post, "/forum/sites/#{site.origin}/refresh"},
          {:delete, "/forum/my-offers/#{offer.id}"}
        ] do
      answer =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, ~s({"agent_name":"kettle","title":"t","body":"b"}))

      assert answer.status == 401, "#{method} #{path} answered #{answer.status} unsigned"
    end

    assert waiting?(item)
    # Every Credits help post, which no single reader may see: none was asked.
    assert Ash.read!(CreditsHelp.Post, authorize?: false) == []
    assert PatchbayWeb.Forum.SiteChecks.current(site.origin) == check
    assert offer_ids(agent.owner) == [offer.id]
  end

  test "an agent deletes its person's never-bid Offer for good; another's, or one bid with, stays",
       %{
         conn: conn,
         agent: agent,
         other: other
       } do
    mine = saved_offer!(agent.owner, "Bookings amended in one call.")
    theirs = saved_offer!(other.owner, "Tables found in one call.")

    # Another account's Offer is not found, and stays.
    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> signed(agent)
             |> delete("/forum/my-offers/#{theirs.id}")
             |> json_response(404)

    assert offer_ids(other.owner) == [theirs.id]

    assert %{"deleted" => true, "creative_id" => id} =
             conn |> signed(agent) |> delete("/forum/my-offers/#{mine.id}") |> json_response(200)

    assert id == mine.id
    assert offer_ids(agent.owner) == []

    # Gone for good: again is not found.
    assert conn |> signed(agent) |> delete("/forum/my-offers/#{mine.id}") |> json_response(404)

    # An Offer bid with keeps its record of where Credits went, so it stays.
    version =
      OffersFixtures.approved_version(agent.owner, "Bid on once.", Offers.global_market!())

    OffersFixtures.lead_next(Offers.global_market!(), 1, version, 100)
    bid_on = Ash.load!(version, :creative, authorize?: false).creative

    assert %{"error" => %{"code" => "has_bids"}} =
             conn
             |> signed(agent)
             |> delete("/forum/my-offers/#{bid_on.id}")
             |> json_response(409)

    assert offer_ids(agent.owner) == [bid_on.id]
  end

  # Each new agent operation's answer has the shape /openapi.json gives it,
  # so a client generated from the document reads it.
  test "each new agent operation answers in its OpenAPI response schema", %{
    conn: conn,
    agent: agent
  } do
    item = notify!(agent.owner)
    offer = saved_offer!(agent.owner, "Shaped as documented.")
    site = Forum.register_site!("documented-refresh.com")
    name = "kettle-#{System.unique_integer([:positive])}"

    asked =
      conn
      |> signed(agent)
      |> post("/forum/credits-help", Jason.encode!(%{"title" => "Shape", "body" => "Checked."}))

    calls = [
      {"renameMyAgent", 200,
       conn |> signed(agent) |> post("/forum/agent-name", Jason.encode!(%{"agent_name" => name}))},
      {"readInbox", 200, conn |> signed(agent) |> post("/forum/inbox", "{}")},
      {"acknowledgeInboxItem", 200,
       conn |> signed(agent) |> post("/forum/inbox/#{item.id}/acknowledge", "{}")},
      {"askCreditsHelp", 201, asked},
      {"listCreditsHelp", 200, conn |> signed(agent) |> post("/forum/credits-help/list", "{}")},
      {"getCreditsHelp", 200,
       conn |> signed(agent) |> get("/forum/credits-help/#{json_response(asked, 201)["post_id"]}")},
      {"refreshSite", 202,
       conn |> signed(agent) |> post("/forum/sites/#{site.origin}/refresh", "{}")},
      {"deleteAgentOffer", 200, conn |> signed(agent) |> delete("/forum/my-offers/#{offer.id}")}
    ]

    for {operation, status, answer} <- calls do
      body = json_response(answer, status)

      assert {:ok, _valid} = JSV.validate(body, response_schema(operation, status)),
             "#{operation} answered outside its OpenAPI schema: #{inspect(body, limit: 8)}"
    end
  end

  test "an agent reads its person's inbox and acknowledges an item; another account's stays", %{
    conn: conn,
    agent: agent,
    other: other
  } do
    mine = notify!(agent.owner)
    theirs = notify!(other.owner)

    assert %{"items" => [item], "pagination" => %{"has_more" => false, "next_cursor" => nil}} =
             conn |> signed(agent) |> post("/forum/inbox", "{}") |> json_response(200)

    assert item["notification_id"] == mine.id
    assert item["kind"] == "thread_posted"
    assert item["title"] == "Who hears about this?"

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> signed(agent)
             |> post("/forum/inbox/#{theirs.id}/acknowledge", "{}")
             |> json_response(404)

    assert waiting?(theirs)

    assert %{"acknowledged" => true, "notification_id" => id} =
             conn
             |> signed(agent)
             |> post("/forum/inbox/#{mine.id}/acknowledge", "{}")
             |> json_response(200)

    assert id == mine.id
    refute waiting?(mine)

    # Acknowledged once, it has left the inbox: again is not found.
    assert conn
           |> signed(agent)
           |> post("/forum/inbox/#{mine.id}/acknowledge", "{}")
           |> json_response(404)

    assert %{"items" => []} =
             conn |> signed(agent) |> post("/forum/inbox", "{}") |> json_response(200)

    assert %{"error" => %{"code" => "invalid_cursor"}} =
             conn
             |> signed(agent)
             |> post("/forum/inbox", ~s({"after":"not-a-cursor"}))
             |> json_response(422)
  end

  test "an agent asks Credits help for its person and reads the team's answer; nobody else's", %{
    conn: conn,
    agent: agent,
    other: other
  } do
    asked =
      conn
      |> signed(agent)
      |> post(
        "/forum/credits-help",
        Jason.encode!(%{"title" => "Missing top-up", "body" => "Paid, not credited."})
      )
      |> json_response(201)

    assert %{"title" => "Missing top-up", "answers" => []} = asked
    # Read as the test, to see whose post it is: the person's own, as if they
    # had asked on /credits-help.
    post = Ash.get!(CreditsHelp.Post, asked["post_id"], authorize?: false)
    assert post.author_profile_id == agent.owner.id

    moderator = OffersFixtures.moderator()

    {:ok, _answer} =
      CreditsHelp.answer(%{post_id: post.id, body: "Credited now."}, actor: moderator)

    read = conn |> signed(agent) |> get("/forum/credits-help/#{post.id}") |> json_response(200)
    assert [%{"body" => "Credited now."}] = read["answers"]

    assert %{"posts" => [%{"post_id" => listed, "answer_count" => 1}]} =
             conn |> signed(agent) |> post("/forum/credits-help/list", "{}") |> json_response(200)

    assert listed == post.id

    # Another account's agent, and even a moderator's, reads only its own person's posts.
    for stranger <- [other, SignedAgent.pair!(moderator)] do
      assert %{"error" => %{"code" => "not_found"}} =
               conn
               |> signed(stranger)
               |> get("/forum/credits-help/#{post.id}")
               |> json_response(404)

      assert %{"posts" => []} =
               conn
               |> signed(stranger)
               |> post("/forum/credits-help/list", "{}")
               |> json_response(200)
    end

    assert %{"error" => %{"code" => "invalid"}} =
             conn
             |> signed(agent)
             |> post("/forum/credits-help", Jason.encode!(%{"title" => "", "body" => "x"}))
             |> json_response(422)
  end

  test "a refresh runs once a day per site, says when it can run again, and keeps the share", %{
    conn: conn,
    agent: agent
  } do
    site = Forum.register_site!("refresh-once.com")
    path = "/forum/sites/#{site.origin}/refresh"

    assert %{"state" => "refreshing", "site" => origin} =
             conn |> signed(agent) |> post(path, "{}") |> json_response(202)

    assert origin == site.origin

    assert %{"error" => %{"code" => "refresh_running"}} =
             conn |> signed(agent) |> post(path, "{}") |> json_response(409)

    # A picture taken an hour ago: the next refresh is a day after it.
    fresh = Forum.register_site!("fresh-picture.com")
    taken = DateTime.add(DateTime.utc_now(), -3600, :second)

    Patchbay.Repo.query!("UPDATE forum_sites SET screenshot_captured_at = $1 WHERE id = $2", [
      taken,
      Ecto.UUID.dump!(fresh.id)
    ])

    assert %{"error" => %{"code" => "refreshed_recently", "refresh_after" => next_time}} =
             conn
             |> signed(agent)
             |> post("/forum/sites/#{fresh.origin}/refresh", "{}")
             |> json_response(409)

    {:ok, again, _offset} = DateTime.from_iso8601(next_time)
    assert DateTime.diff(again, taken) == 86_400

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> signed(agent)
             |> post("/forum/sites/nowhere.example.org/refresh", "{}")
             |> json_response(404)

    # Twenty asks in ten minutes, the same share a visitor on the page has.
    for _ask <- 1..20,
        do:
          PatchbayWeb.ReadLimit.hit(
            "site-check:pairing:" <> agent.pairing.id,
            :timer.minutes(10),
            20
          )

    due = Forum.register_site!("due-refresh.com")

    assert %{"error" => %{"code" => "rate_limited"}} =
             conn
             |> signed(agent)
             |> post("/forum/sites/#{due.origin}/refresh", "{}")
             |> json_response(429)
  end

  defp signed(conn, agent), do: conn |> recycle() |> SignedAgent.sign(agent)

  defp saved_offer!(owner, text) do
    {:ok, creative} = Offers.create_creative("Offer", text, Ecto.UUID.generate(), actor: owner)
    creative
  end

  defp offer_ids(owner), do: owner |> then(&Offers.my_creatives!(actor: &1)) |> Enum.map(& &1.id)

  # `operation`'s `status` response schema, with the document's components so
  # its references resolve.
  defp response_schema(operation, status) do
    openapi = "priv/public/openapi.json" |> File.read!() |> Jason.decode!()

    [schema] =
      for {_path, methods} <- openapi["paths"],
          {_method, %{"operationId" => ^operation} = entry} <- methods,
          do: entry["responses"]["#{status}"]["content"]["application/json"]["schema"]

    schema |> Map.put("components", openapi["components"]) |> JSV.build!()
  end

  # One question on a site, delivered to `owner`'s inbox as the fan-out would.
  defp notify!(owner) do
    site = Forum.register_site!("inbox-#{System.unique_integer([:positive])}.example.com")

    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    report =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "Who hears about this?",
          thread_kind: :help_needed,
          body_markdown: "Asked on the board."
        },
        authorize?: false
      )

    # Events have no public way in; the test reads the one the question wrote.
    event =
      ForumEvent
      |> Ash.Query.filter(thread_id == ^report.id and kind == :thread_posted)
      |> Ash.read_one!(authorize?: false)

    # Delivered as the fan-out worker delivers it, as nobody in particular.
    Ash.create!(Notification, %{event_id: event.id, recipient: Principal.for_profile(owner.id)},
      action: :deliver,
      authorize?: false
    )
  end

  # Read as the test, not as anyone: an item's state whoever it belongs to.
  defp waiting?(notification),
    do: is_nil(Ash.get!(Notification, notification.id, authorize?: false).acknowledged_at)
end
