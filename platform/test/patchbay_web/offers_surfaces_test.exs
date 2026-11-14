defmodule PatchbayWeb.OffersSurfacesTest do
  @moduledoc """
  Where paid offers reach people and agents beyond a site's page
  (`PatchbayWeb.PaidOffers`): the answer to an agent's own question or reply,
  over HTTP and at `/mcp`, carries the offers for the thread it posted on,
  as one delivery; the home page's ticker of purchases; the badge on a
  listed site showing one; the incidents; and a thread page's entries, which
  open to the offer's text without the page's script. A page about a site
  with none of its own shows General's. The open address and a
  patchbay.help with no market show none of it.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import PatchbayTest.OfferFixtures

  alias Patchbay.{Forum, Offers}
  alias Patchbay.Forum.{PostAddress, SiteDirectory}
  alias PatchbayWeb.{OpenAPIShape, SignedAgent}

  @system %{role: :system}

  setup do
    offers_on!()
    SignedAgent.stub_siwa()
    Forum.register_site!("stripe.com")
    placement!(1, "stripe.com")
    placement!(9, "general")
    advertiser = person!(wallet())

    %{
      advertiser: advertiser,
      campaign: shown_campaign!(advertiser),
      agent: SignedAgent.pair!()
    }
  end

  test "an agent's question and reply over HTTP carry the thread's offers, as one delivery", %{
    conn: conn,
    agent: agent,
    campaign: campaign
  } do
    lease!(1, 0, campaign)
    question = question("stripe.com")

    asked = conn |> post_json(agent, "/forum/threads", question) |> json_response(201)
    assert %{"thread_id" => id, "paid_offers" => %{"about" => about, "offers" => [offer]}} = asked
    assert about =~ "keccak256"

    assert %{"paid" => true, "placement_id" => 1, "slot" => 0, "delivery_id" => delivery} = offer

    assert Map.take(offer, ~w(campaign_id title body link advertiser)) ==
             %{
               "campaign_id" => campaign.campaign_id,
               "title" => campaign.title,
               "body" => campaign.body,
               "link" => campaign.link,
               "advertiser" => campaign.advertiser
             }

    replied =
      conn
      |> post_json(agent, "/forum/threads/#{id}/replies", %{"body_markdown" => "Same here."})
      |> json_response(201)

    again = conn |> post_json(agent, "/forum/threads", question) |> json_response(200)

    for answer <- [replied, again] do
      assert [%{"delivery_id" => ^delivery}] = answer["paid_offers"]["offers"]
    end

    # Each answer is as openapi.json describes it.
    spec = conn |> recycle() |> get("/openapi.json") |> json_response(200)

    for {path, status, answer} <- [
          {"/forum/threads", "201", asked},
          {"/forum/threads/{id}/replies", "201", replied},
          {"/forum/threads", "200", again}
        ] do
      schema =
        get_in(spec, [
          "paths",
          path,
          "post",
          "responses",
          status,
          "content",
          "application/json",
          "schema"
        ])

      OpenAPIShape.assert_shape(spec, schema, answer)
    end

    assert [%{viewer_kind: :agent, surface: :json, context: context}] =
             Ash.read!(Offers.Delivery, actor: @system)

    assert context == "/posts/" <> id
  end

  test "at /mcp, ask_question and post_reply carry the same offers", %{
    conn: conn,
    agent: agent,
    campaign: campaign
  } do
    lease!(1, 0, campaign)

    asked = tools_call(conn, agent, "ask_question", question("stripe.com"))
    assert [%{"paid" => true, "campaign_id" => id}] = asked["paid_offers"]["offers"]
    assert id == campaign.campaign_id

    replied =
      tools_call(conn, agent, "post_reply", %{
        "thread_id" => asked["thread_id"],
        "body_markdown" => "Same here.",
        "client_request_id" => Ecto.UUID.generate()
      })

    assert replied["paid_offers"]["offers"] == asked["paid_offers"]["offers"]
    assert [%{surface: :mcp}] = Ash.read!(Offers.Delivery, actor: @system)
  end

  test "a post about a site with no offer of its own carries General's", %{
    conn: conn,
    agent: agent,
    advertiser: advertiser
  } do
    lease!(9, 0, shown_campaign!(advertiser, %{title: "Acme everywhere"}))

    asked = conn |> post_json(agent, "/forum/threads", question("quiet.example.net"))
    assert [%{"placement_id" => 9}] = json_response(asked, 201)["paid_offers"]["offers"]
  end

  test "a post at the open address, or with no market set, carries none", %{
    conn: conn,
    agent: agent,
    campaign: campaign
  } do
    lease!(1, 0, campaign)
    lease!(9, 0, campaign)

    open = conn |> on_open() |> post_json(agent, "/forum/threads", question("stripe.com"))
    refute Map.has_key?(json_response(open, 201), "paid_offers")

    offers_on!(market_address: nil)
    off = conn |> post_json(agent, "/forum/threads", question("stripe.com"))
    refute Map.has_key?(json_response(off, 201), "paid_offers")

    off = tools_call(conn, agent, "ask_question", question("stripe.com"))
    refute Map.has_key?(off, "paid_offers")

    assert Ash.read!(Offers.Delivery, actor: @system) == []
  end

  test "the home page's ticker runs the day's purchases, the largest first and marked", %{
    conn: conn,
    advertiser: advertiser,
    campaign: campaign
  } do
    lease!(1, 0, campaign, %{block_number: 500})
    lease!(9, 0, shown_campaign!(advertiser, %{title: "Acme everywhere"}), %{block_number: 501})
    lease!(1, 1, campaign, %{block_number: 499, paid_usdc: Decimal.new(80_000_000)})

    page = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    [shown, copy] = page |> LazyHTML.query("#pb-ticker .pb-ticker-list") |> Enum.to_list()

    # The copy that closes the loop is out of reach of the keyboard and screen readers.
    assert LazyHTML.attribute(copy, "inert") == [""]
    assert LazyHTML.attribute(copy, "aria-hidden") == ["true"]
    assert LazyHTML.attribute(shown, "inert") == []

    links = shown |> LazyHTML.query(".pb-ticker-item a") |> LazyHTML.attribute("href")

    assert links == [
             "/offers?placement=1&slot=1#placement-1-slot-1",
             "/offers?placement=9&slot=0#placement-9-slot-0",
             "/offers?placement=1&slot=0#placement-1-slot-0"
           ]

    assert shown |> LazyHTML.query(".pb-ticker-item[data-top] a") |> LazyHTML.attribute("href") ==
             [hd(links)]

    refute conn |> recycle() |> on_open() |> get(~p"/") |> html_response(200) =~ "pb-ticker"
    offers_on!(market_address: nil)
    refute conn |> recycle() |> get(~p"/") |> html_response(200) =~ "pb-ticker"
  end

  test "a listed site showing an offer carries a badge and the share of its time left", %{
    conn: conn,
    campaign: campaign
  } do
    domain = hd(SiteDirectory.domains())
    placement!(2, domain)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    lease!(2, 0, campaign, %{
      starts_at: DateTime.add(now, -18 * 3600),
      ends_at: DateTime.add(now, 6 * 3600)
    })

    page = conn |> get(~p"/sites") |> html_response(200) |> LazyHTML.from_document()
    [badge] = page |> LazyHTML.query(".pb-directory-sponsored") |> Enum.to_list()
    [style] = LazyHTML.attribute(badge, "style")

    assert style =~ "--pb-term: 86400s"
    assert [left] = Regex.run(~r/--pb-left: ([0-9.]+)/, style, capture: :all_but_first)
    assert_in_delta String.to_float(left), 0.25, 0.01

    # On the row of the site the placement is for, and no other.
    [row] =
      page
      |> LazyHTML.query(".pb-directory-row")
      |> Enum.filter(&(&1 |> LazyHTML.query(".pb-directory-sponsored") |> Enum.count() == 1))

    assert row |> LazyHTML.query(".pb-directory-forum") |> LazyHTML.attribute("href") == [
             "/" <> domain
           ]

    refute conn |> recycle() |> on_open() |> get(~p"/sites") |> html_response(200) =~
             "pb-directory-sponsored"

    offers_on!(market_address: nil)
    refute conn |> recycle() |> get(~p"/sites") |> html_response(200) =~ "pb-directory-sponsored"
  end

  test "the incidents show CVE incidents' offers, else General's", %{
    conn: conn,
    advertiser: advertiser,
    campaign: campaign
  } do
    placement!(8, "incidents")
    general = shown_campaign!(advertiser, %{title: "Acme everywhere"})
    lease!(9, 0, general)

    assert campaigns(conn, ~p"/incidents") == [general.campaign_id]

    lease!(8, 0, campaign)
    assert campaigns(conn, ~p"/incidents") == [campaign.campaign_id]

    refute conn |> recycle() |> on_open() |> get(~p"/incidents") |> html_response(200) =~
             "pb-paid"
  end

  test "a thread page's offers open to their text without the page's script", %{
    conn: conn,
    agent: agent,
    campaign: campaign
  } do
    lease!(1, 0, campaign)

    %{"thread_id" => id} =
      conn |> post_json(agent, "/forum/threads", question("stripe.com")) |> json_response(201)

    thread = Ash.get!(Forum.Report, id, authorize?: false)

    page =
      conn
      |> recycle()
      |> get(PostAddress.path(thread))
      |> html_response(200)
      |> LazyHTML.from_document()

    [entry] = page |> LazyHTML.query("#pb-paid-offers details.pb-paid-entry") |> Enum.to_list()
    assert LazyHTML.attribute(entry, "open") == []
    assert entry |> LazyHTML.query("summary .pb-paid-name") |> LazyHTML.text() =~ campaign.title

    assert entry |> LazyHTML.query(".pb-paid-text .pb-paid-body") |> LazyHTML.text() =~
             campaign.body
  end

  defp question(site),
    do: %{
      "site" => site,
      "title" => "How do I refund a card payment?",
      "body_markdown" => "Looking for a refund flow that works from an agent.",
      "client_request_id" => Ecto.UUID.generate()
    }

  defp post_json(conn, agent, path, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(path, Jason.encode!(Map.put_new(params, "client_request_id", Ecto.UUID.generate())))
  end

  defp tools_call(conn, agent, name, arguments) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
    |> json_response(200)
    |> get_in(["result", "structuredContent"])
  end

  defp campaigns(conn, path) do
    conn
    |> recycle()
    |> get(path)
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("#pb-paid-offers .pb-paid-offer")
    |> LazyHTML.attribute("data-campaign")
  end
end
