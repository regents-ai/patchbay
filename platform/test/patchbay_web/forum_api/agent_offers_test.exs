defmodule PatchbayWeb.ForumAPI.AgentOffersTest do
  # Agent Offers after a new post: each position is filled on its own from
  # the site's slot of that number or General's, only copy that may be shown
  # is returned, a repeated post carries none, and the forum result always
  # comes first.
  #
  # General's three slots are shared by every test, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures

  alias Patchbay.Forum
  alias Patchbay.Offers

  setup do
    origin = "offers-#{System.unique_integer([:positive])}.example"
    {:ok, site} = Forum.register_site(origin, authorize?: false)

    %{
      origin: origin,
      site: Offers.open_site_market!(site.id, authorize?: false),
      general: Offers.general_market!(),
      owner: advertiser()
    }
  end

  test "each position is the site's slot, else General's of the same number, never moved",
       %{conn: conn, origin: origin, site: site, general: general, owner: owner} do
    place(site, 3, approved_version(owner, "Site three", site))
    place(general, 1, approved_version(owner, "General one", general))
    place(general, 3, approved_version(owner, "General three", general))

    posted = ask(conn, origin)
    body = json_response(posted, 201)

    assert %{"items" => items} = offers = body["agent_offers"]
    assert offers["disclosure_version"] == "agent-offers-v1"
    assert offers["disclosure"] =~ "Eligible responses for #{origin}"

    assert Enum.map(items, &{&1["position"], &1["label"], &1["text"]}) == [
             {1, "General · Slot 1", "General one"},
             {3, "Site · Slot 3", "Site three"}
           ]

    # The forum result comes first, the Offers after it.
    {result_at, _} = :binary.match(posted.resp_body, ~s("thread_id"))
    {offers_at, _} = :binary.match(posted.resp_body, ~s("agent_offers"))
    assert result_at < offers_at

    delivery = Ash.get!(Offers.Delivery, offers["delivery_id"], authorize?: false)
    assert delivery.general_opportunities == [1, 2]
  end

  test "blocked, expired, stale or other-market copy is not shown, and General stands in",
       %{conn: conn, origin: origin, site: site, general: general, owner: owner} do
    {:ok, other_site} = Forum.register_site("elsewhere-offers.example", authorize?: false)
    other = Offers.open_site_market!(other_site.id, authorize?: false)

    blocked = approved_version(owner, "Blocked", site)
    place(site, 1, blocked)

    blocked
    |> Ash.Changeset.for_update(:block, %{reason: "misleading"})
    |> Ash.update!(authorize?: false)

    place(site, 2, approved_version(owner, "Ran out", site),
      starts_at: DateTime.add(DateTime.utc_now(), -73, :hour)
    )

    place(site, 3, approved_version(owner, "Suits another site", other))

    place(general, 1, approved_version(owner, "General one", general))

    place(
      general,
      2,
      approved_version(owner, "Stale", general,
        fresh_until: DateTime.add(DateTime.utc_now(), -1, :minute)
      )
    )

    place(general, 3, approved_version(owner, "General three", general))

    items = conn |> ask(origin) |> json_response(201) |> get_in(["agent_offers", "items"])

    assert Enum.map(items, &{&1["label"], &1["text"]}) == [
             {"General · Slot 1", "General one"},
             {"General · Slot 3", "General three"}
           ]
  end

  test "a post with nothing showing has no Offers section, and a repeat never has one",
       %{conn: conn, origin: origin, general: general, owner: owner} do
    first = ask(conn, origin, %{"client_request_id" => "same-question"})
    refute Map.has_key?(json_response(first, 201), "agent_offers")

    place(general, 2, approved_version(owner, "General two", general))

    repeated = ask(first, origin, %{"client_request_id" => "same-question"})
    body = json_response(repeated, 200)
    assert body["repeated"] == true
    refute Map.has_key?(body, "agent_offers")

    replied =
      repeated
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/forum/threads/#{body["thread_id"]}/replies",
        Jason.encode!(%{"body_markdown" => "Here is what worked for me."})
      )

    assert [%{"label" => "General · Slot 2"}] =
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

  defp ask(conn, origin, extra \\ %{}) do
    conn
    |> recycle()
    |> get("/")
    |> recycle()
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
