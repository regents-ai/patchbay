defmodule Patchbay.Offers.MarketLabTest do
  @moduledoc """
  Agent offers end to end against the real contracts on anvil: a placement is
  made, an advertiser writes a campaign, Patchbay approves it and admits the
  purchase, the advertiser approves and buys with the steps the page sends,
  the record shows the lease, a rival buys the slot out, and the first
  advertiser claims the refund. The offer bought is shown over HTTP and at
  `/mcp` until Patchbay pulls it, and the publisher's ending of the placement
  refunds it on Base. The market itself checks every admission: it takes
  Patchbay's signature and refuses one made over any other value of each
  field.

  Left out of the default run. Start anvil as Base on this machine, then run
  this file alone:

      anvil --chain-id 8453 --host 127.0.0.1 --port 58621 --silent &
      mix test --only anvil test/patchbay/offers/market_lab_test.exs

  The contracts must be built first (`forge build` in contracts/).
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import PatchbayTest.OfferFixtures, only: [person!: 1, rule!: 1, rule!: 2, approve!: 1]

  alias Patchbay.{Forum, Offers}
  alias Patchbay.Offers.{Admission, Board, Market, Node, Publisher, Scanner, Steps}
  alias PatchbayDev.OffersLab

  @moduletag :anvil
  @rpc_url "http://127.0.0.1:58621"

  setup do
    %{market: market, from_block: from_block} = OffersLab.deploy(@rpc_url)

    original = Application.fetch_env!(:patchbay, Offers)
    nodes = Application.fetch_env!(:patchbay, :chain_nodes)

    Application.put_env(
      :patchbay,
      Offers,
      Keyword.merge(original,
        market_address: market,
        wallet_rpc_url: @rpc_url,
        from_block: from_block,
        publisher_private_key: OffersLab.publisher_key(),
        client: Node
      )
    )

    Application.put_env(:patchbay, :chain_nodes, Map.put(nodes, 8453, @rpc_url))

    on_exit(fn ->
      Application.put_env(:patchbay, Offers, original)
      Application.put_env(:patchbay, :chain_nodes, nodes)
    end)

    OffersLab.place!(@rpc_url, market, "stripe.com")
    OffersLab.place!(@rpc_url, market, "openai.com")
    assert :ok = Scanner.pass(Node, 8453, market)

    accounts = OffersLab.accounts()
    advertiser = person!(accounts.advertiser)
    rival = person!(accounts.rival)

    Enum.each([accounts.advertiser, accounts.rival], &rule!/1)

    %{market: market, accounts: accounts, advertiser: advertiser, rival: rival}
  end

  test "a purchase, a buyout, a refund and a claim, recorded from the chain", %{
    market: market,
    accounts: accounts,
    advertiser: advertiser,
    rival: rival
  } do
    assert [%{source_origin: "stripe.com"} = stripe, %{source_origin: "openai.com"}] =
             Offers.open_placements!(8453, market)

    campaign =
      PatchbayTest.OfferFixtures.campaign!(advertiser, %{audience: :sites, sites: ["stripe.com"]})

    approve!(campaign)

    # The campaign runs only on Stripe's page.
    assert {:error, :not_on_site} = Admission.admit(advertiser, campaign, 2, 0, 5_000_000, 0)

    assert {:ok, admission} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    assert admission.buyer == accounts.advertiser
    sent!(accounts.advertiser, Steps.approve(5_000_000))
    sent!(accounts.advertiser, Steps.buy(admission))

    assert :ok = Scanner.pass(Node, 8453, market)

    assert %{placements: [%{slots: [first | _]} | _]} = Board.read()
    assert first.lease.buyer == accounts.advertiser
    assert first.offer.campaign_id == campaign.campaign_id
    assert Decimal.equal?(first.lease.paid_usdc, 5_000_000)
    assert first.minimum_usdc == 5_500_000
    assert {:ok, 5_500_000} = Market.minimum_price(stripe.placement_id, 0)

    # A rival buys the slot out at the minimum; the first lease is refunded
    # for the time it had left.
    rival_campaign = PatchbayTest.OfferFixtures.campaign!(rival, %{title: "Rival payments"})
    approve!(rival_campaign)
    OffersLab.wait!(@rpc_url, 60)

    assert {:ok, buyout} =
             Admission.admit(rival, rival_campaign, stripe.placement_id, 0, 5_500_000, 1)

    sent!(accounts.rival, Steps.approve(5_500_000))
    sent!(accounts.rival, Steps.buy(buyout))
    assert :ok = Scanner.pass(Node, 8453, market)

    assert %{placements: [%{slots: [first | _]} | _]} = Board.read()
    assert first.offer.campaign_id == rival_campaign.campaign_id
    assert first.lease.nonce == 2

    assert [%{reason: :bought_out, buyer: buyer, refund_usdc: refund}] =
             Ash.read!(Offers.Settlement)

    assert buyer == accounts.advertiser
    assert {:ok, claimable} = Market.claimable(accounts.advertiser)
    assert claimable == Decimal.to_integer(refund)
    assert claimable > 0 and claimable < 5_000_000

    {:ok, before} = Market.balance(accounts.advertiser)
    sent!(accounts.advertiser, Steps.claim(accounts.advertiser))
    assert {:ok, 0} = Market.claimable(accounts.advertiser)
    assert {:ok, after_claim} = Market.balance(accounts.advertiser)
    assert after_claim - before == claimable

    # Read again, the record is unchanged.
    assert :ok = Scanner.pass(Node, 8453, market)
    assert length(Ash.read!(Offers.Lease)) == 2
  end

  test "the market takes Patchbay's admission and refuses one signed over any other value", %{
    market: market,
    accounts: accounts,
    advertiser: advertiser
  } do
    [stripe | _] = Offers.open_placements!(8453, market)
    campaign = PatchbayTest.OfferFixtures.campaign!(advertiser)
    approve!(campaign)

    assert {:ok, admission} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    sent!(accounts.advertiser, Steps.approve(5_000_000))
    buy = Steps.buy(admission)
    assert :ok = simulate(accounts.advertiser, buy)

    # From any other wallet the same purchase is refused.
    assert {:error, "InvalidPermit"} = simulate(accounts.rival, buy)

    typed = Admission.typed_data(admission.purchase, stripe.source_id, admission.buyer)
    {:ok, publisher} = Publisher.signer()

    wrong = %{
      "placementId" => 2,
      "slot" => 1,
      "sourceId" => Offers.hash("openai.com"),
      "buyer" => accounts.rival,
      "campaignId" => Offers.hash("another campaign"),
      "policyHash" => Offers.hash("patchbay-policy-v2"),
      "amountUSDC" => 5_000_001,
      "expectedLeaseNonce" => 1,
      "deadline" => admission.purchase.deadline + 1
    }

    for {field, value} <- wrong do
      {:ok, digest} = RegentChain.Typed.digest(put_in(typed, ["message", field], value))
      forged = %{admission | permit: Publisher.sign(publisher, digest)}

      assert {:error, "InvalidPermit"} = simulate(accounts.advertiser, Steps.buy(forged)),
             "a signature over another #{field} was taken"
    end

    # A signature for another chain or another market is refused too.
    for {field, value} <- [{"chainId", 1}, {"verifyingContract", accounts.payout}] do
      {:ok, digest} = RegentChain.Typed.digest(put_in(typed, ["domain", field], value))
      forged = %{admission | permit: Publisher.sign(publisher, digest)}
      assert {:error, "InvalidPermit"} = simulate(accounts.advertiser, Steps.buy(forged))
    end
  end

  test "Patchbay admits nobody it has not accepted, nor anyone it blocked", %{
    market: market,
    accounts: accounts,
    advertiser: advertiser
  } do
    [stripe | _] = Offers.open_placements!(8453, market)
    campaign = PatchbayTest.OfferFixtures.campaign!(advertiser)

    rule!(accounts.advertiser, :blocked)

    assert {:error, :blocked} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    stranger = person!(OffersLab.accounts().payout)
    unknown = PatchbayTest.OfferFixtures.campaign!(stranger)

    assert {:error, :not_accepted} =
             Admission.admit(stranger, unknown, stripe.placement_id, 0, 5_000_000, 0)
  end

  test "bought and approved, it is shown over HTTP and at /mcp; pulled, it is gone at once", %{
    conn: conn,
    market: market,
    accounts: accounts,
    advertiser: advertiser
  } do
    [stripe | _] = Offers.open_placements!(8453, market)
    thread = thread!("stripe.com")
    campaign = PatchbayTest.OfferFixtures.campaign!(advertiser)

    # Patchbay admits nothing it has not approved.
    assert {:error, :not_approved} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    approve!(campaign)

    assert {:ok, admission} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    sent!(accounts.advertiser, Steps.approve(5_000_000))
    sent!(accounts.advertiser, Steps.buy(admission))
    assert :ok = Scanner.pass(Node, 8453, market)

    assert [%{"campaign_id" => id, "paid" => true}] = over_http(conn, thread)
    assert id == campaign.campaign_id
    assert [%{"campaign_id" => ^id}] = at_mcp(conn, thread)
    assert conn |> recycle() |> get("/stripe.com") |> html_response(200) =~ campaign.title

    Offers.pull_campaign!(campaign.campaign_id, %{reason: "Misleading"}, actor: moderator())

    assert over_http(conn, thread) == []
    assert at_mcp(conn, thread) == []
    refute conn |> recycle() |> get("/stripe.com") |> html_response(200) =~ campaign.title

    # Its money follows the market's own path: the publisher's wallet ends the
    # placement, anyone settles the slot, and the advertiser may claim.
    sent!(accounts.publisher, %{
      to: market,
      data: RegentChain.Call.encode("terminatePlacement(uint256)", [stripe.placement_id])
    })

    sent!(accounts.rival, %{
      to: market,
      data: RegentChain.Call.encode("settleTerminated(uint256,uint16)", [stripe.placement_id, 0])
    })

    assert :ok = Scanner.pass(Node, 8453, market)

    assert [%{reason: :terminated, buyer: buyer, refund_usdc: refund}] =
             Ash.read!(Offers.Settlement)

    assert buyer == accounts.advertiser
    assert {:ok, claimable} = Market.claimable(accounts.advertiser)
    assert claimable == Decimal.to_integer(refund) and claimable > 0
  end

  defp thread!(origin) do
    site = Forum.register_site!(origin)

    # A question to show the offer beside; who may ask is not what this tests.
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: "How do I refund a card payment?",
        thread_kind: :help_needed,
        body_markdown: "Looking for a refund flow."
      },
      authorize?: false
    )
  end

  defp over_http(conn, thread) do
    answer = conn |> recycle() |> get("/forum/threads/#{thread.id}") |> json_response(200)
    get_in(answer, ["paid_offers", "offers"]) || []
  end

  defp at_mcp(conn, thread) do
    %{"result" => %{"structuredContent" => answer}} =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "get_thread", arguments: %{thread_id: thread.id}}
        })
      )
      |> json_response(200)

    get_in(answer, ["paid_offers", "offers"]) || []
  end

  defp sent!(from, step) do
    receipt = OffersLab.send(@rpc_url, from, step.to, step.data)
    assert receipt["status"] == "0x1"
  end

  # The market's answer to the step sent from `from`, without sending it:
  # `:ok`, or the name of the error it reverts with.
  defp simulate(from, step) do
    case OffersLab.rpc(@rpc_url, "eth_call", [
           %{from: from, to: step.to, data: step.data},
           "latest"
         ]) do
      {:ok, _returned} ->
        :ok

      {:error, %{"data" => "0x" <> <<selector::binary-size(8), _rest::binary>>}} ->
        {:error, error_name(selector)}
    end
  end

  @errors [
    "InvalidPermit()",
    "StaleLeaseNonce(uint64)",
    "AmountBelowMinimum(uint256)",
    "PurchaseExpired()"
  ]

  defp error_name(selector) do
    case Enum.find(@errors, &(RegentChain.Call.selector(&1) == "0x" <> String.downcase(selector))) do
      nil -> selector
      signature -> signature |> String.split("(") |> hd()
    end
  end
end
