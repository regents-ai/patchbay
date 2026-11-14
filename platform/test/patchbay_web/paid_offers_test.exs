defmodule PatchbayWeb.PaidOffersTest do
  @moduledoc """
  Paid offers at each door that shows them (`PatchbayWeb.PaidOffers`): beside
  a site's page and in its Markdown, beside a thread and a search narrowed to
  the site as JSON over HTTP, and in `search_threads` and `get_thread` at
  `/mcp`. Each is marked paid, carries its title, text and link as sealed and
  its campaign id, which hashes the manifest Patchbay serves. The answer
  beside it is unchanged. At `/mcp` a read a paired agent signed is also shown
  the offers made for paired agents; any other read is a visitor's, never
  refused. The open address, the ChatGPT plugin and a patchbay.help with no
  market show none.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import PatchbayTest.OfferFixtures

  alias Patchbay.{Forum, Offers}
  alias PatchbayWeb.SignedAgent

  setup do
    offers_on!()
    site = Forum.register_site!("stripe.com")
    placement!(1, "stripe.com")
    advertiser = person!(wallet())
    campaign = shown_campaign!(advertiser)
    lease!(1, 0, campaign)

    # A question to show the offer beside; who may ask is not what this tests.
    thread =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "How do I refund a card payment?",
          thread_kind: :help_needed,
          topic_tags: ["payments"],
          body_markdown: "Looking for a refund flow."
        },
        authorize?: false
      )

    %{advertiser: advertiser, campaign: campaign, thread: thread}
  end

  test "a site's page shows the offer apart from the answer, marked paid, as sealed", %{
    conn: conn,
    campaign: campaign
  } do
    page = conn |> get(~p"/stripe.com") |> html_response(200) |> LazyHTML.from_document()
    offer = LazyHTML.query(page, "#pb-paid-offers .pb-paid-offer")
    text = &(offer |> LazyHTML.query(&1) |> LazyHTML.text() |> String.trim())

    assert Enum.count(offer) == 1
    assert LazyHTML.attribute(offer, "data-campaign") == [campaign.campaign_id]
    assert text.(".pb-paid-mark") == "Paid"
    assert text.(".pb-paid-name") == campaign.title
    assert text.(".pb-paid-body") == campaign.body
    assert LazyHTML.attribute(LazyHTML.query(offer, "a"), "href") == [campaign.link]
    assert LazyHTML.attribute(LazyHTML.query(offer, "a"), "rel") == ["sponsored noopener"]

    markdown =
      conn |> recycle() |> put_req_header("accept", "text/markdown") |> get(~p"/stripe.com")

    body = response(markdown, 200)
    assert body =~ "## Paid offers"
    assert body =~ "Campaign `#{campaign.campaign_id}`"
    assert body =~ "<#{campaign.link}>"
  end

  test "a thread and a search narrowed to its site carry the offer beside an unchanged answer", %{
    conn: conn,
    campaign: campaign,
    thread: thread
  } do
    with_offers = conn |> get("/forum/threads/#{thread.id}") |> json_response(200)

    assert %{"paid_offers" => %{"about" => about, "offers" => [offer]}} = with_offers
    assert about =~ "keccak256"

    assert %{
             "paid" => true,
             "title" => title,
             "body" => body,
             "link" => link,
             "advertiser" => advertiser,
             "placement_id" => 1,
             "slot" => 0,
             "manifest_url" => manifest_url
           } = offer

    assert {title, body, link, advertiser} ==
             {campaign.title, campaign.body, campaign.link, campaign.advertiser}

    # The manifest hashes to the campaign id the purchase named on Base.
    manifest = conn |> recycle() |> get(URI.parse(manifest_url).path) |> response(200)
    assert Offers.hash(manifest) == offer["campaign_id"]
    assert offer["campaign_id"] == campaign.campaign_id

    searched = conn |> recycle() |> get("/forum/search?origin=stripe.com") |> json_response(200)
    assert [%{"campaign_id" => id}] = searched["paid_offers"]["offers"]
    assert id == campaign.campaign_id

    refute Map.has_key?(
             conn |> recycle() |> get("/forum/search?q=refund") |> json_response(200),
             "paid_offers"
           )

    offers_on!(market_address: nil)
    without = conn |> recycle() |> get("/forum/threads/#{thread.id}") |> json_response(200)
    assert steady(Map.delete(with_offers, "paid_offers")) == steady(without)
  end

  test "at /mcp, search_threads and get_thread carry offers; a reader who proved nothing gets none that need proof",
       %{conn: conn, advertiser: advertiser, thread: thread} do
    lease!(1, 1, shown_campaign!(advertiser, %{title: "Paired only", requires: [:paired]}))

    for {name, arguments} <- reads(thread) do
      assert ["Acme payments"] = titles(tools_call(conn, name, arguments)),
             "#{name} answered without its offer"
    end
  end

  test "at /mcp, a read signed by a paired agent also carries the offers made for paired agents, beside the same answer",
       %{conn: conn, advertiser: advertiser, thread: thread} do
    SignedAgent.stub_siwa()
    agent = SignedAgent.pair!()
    lease!(1, 1, shown_campaign!(advertiser, %{title: "Paired only", requires: [:paired]}))

    for {name, arguments} <- reads(thread) do
      signed = signed_call(conn, &SignedAgent.sign(&1, agent), name, arguments)
      unsigned = tools_call(conn, name, arguments)

      assert ["Acme payments", "Paired only"] = titles(signed), "#{name} signed"
      assert ["Acme payments"] = titles(unsigned), "#{name} unsigned"
      assert answer(signed) == answer(unsigned)
    end
  end

  test "at /mcp, a signature that does not hold, an agent not paired and a spent signed share read as a visitor",
       %{conn: conn, advertiser: advertiser, thread: thread} do
    SignedAgent.stub_siwa()
    agent = SignedAgent.pair!()
    lease!(1, 1, shown_campaign!(advertiser, %{title: "Paired only", requires: [:paired]}))
    {name, arguments} = hd(reads(thread))
    unsigned = tools_call(conn, name, arguments)

    old = Application.fetch_env!(:patchbay, :signed_per_minute)
    Application.put_env(:patchbay, :signed_per_minute, 1)
    on_exit(fn -> Application.put_env(:patchbay, :signed_per_minute, old) end)

    # An address nothing else uses, whose one signed read a minute is spent here.
    address = {0x2001, 0xDB8, :rand.uniform(0xFFFF), :rand.uniform(0xFFFF), 0, 0, 0, 3}
    from = &(&1 |> Map.put(:remote_ip, address) |> SignedAgent.sign(agent))
    assert ["Acme payments", "Paired only"] = titles(signed_call(conn, from, name, arguments))

    for {why, sign} <- [
          {"bad signature", &put_req_header(&1, "x-siwa-signature", "not a signature")},
          {"not paired", &SignedAgent.sign(&1, %{wallet: wallet()})},
          {"share spent", from}
        ] do
      read = signed_call(conn, sign, name, arguments)
      assert ["Acme payments"] = titles(read), why
      assert answer(read) == answer(unsigned), why
    end
  end

  test "the open address, the ChatGPT plugin and an unset market show no offers", %{
    conn: conn,
    thread: thread
  } do
    refute conn |> on_open() |> get(~p"/stripe.com") |> html_response(200) =~ "pb-paid"

    refute Map.has_key?(
             conn |> on_open() |> get("/forum/threads/#{thread.id}") |> json_response(200),
             "paid_offers"
           )

    chatgpt =
      tools_call(on_open(conn), "get_thread", %{"thread_id" => thread.id}, "/chatgpt/mcp")

    refute Map.has_key?(chatgpt["structuredContent"], "paid_offers")

    offers_on!(market_address: nil)
    refute conn |> recycle() |> get(~p"/stripe.com") |> html_response(200) =~ "pb-paid"

    assert conn
           |> recycle()
           |> get("/api/offers/campaigns/0x" <> String.duplicate("0", 64))
           |> json_response(404)

    assert Ash.read!(Offers.Delivery, actor: %{role: :system}) == []
  end

  test "a campaign Patchbay has not shown has no manifest to read", %{conn: conn} do
    unknown = "0x" <> String.duplicate("ab", 32)

    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/offers/campaigns/" <> unknown) |> json_response(404)
  end

  defp reads(thread),
    do: [
      {"get_thread", %{"thread_id" => thread.id}},
      {"search_threads", %{"origin" => "stripe.com"}}
    ]

  defp tools_call(conn, name, arguments, path \\ "/mcp"),
    do: conn |> recycle() |> rpc(path, name, arguments)

  # A call `sign` signs, or tries to, after the connection is made anew.
  defp signed_call(conn, sign, name, arguments),
    do: conn |> recycle() |> sign.() |> rpc("/mcp", name, arguments)

  defp rpc(conn, path, name, arguments) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      path,
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp titles(%{"structuredContent" => answer}),
    do: Enum.map(answer["paid_offers"]["offers"], & &1["title"])

  defp answer(%{"structuredContent" => answer}), do: steady(Map.delete(answer, "paid_offers"))

  # An answer without the moments it was read at.
  defp steady(%{} = map), do: Map.new(Map.delete(map, "as_of"), fn {k, v} -> {k, steady(v)} end)
  defp steady(list) when is_list(list), do: Enum.map(list, &steady/1)
  defp steady(value), do: value
end
