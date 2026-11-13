defmodule Patchbay.Offers.MarketLabTest do
  @moduledoc """
  Agent offers end to end against the real contracts on anvil: a placement is
  made, an advertiser writes a campaign, Patchbay admits the purchase, the
  advertiser approves and buys with the steps the page sends, the record shows
  the lease, a rival buys the slot out, and the first advertiser claims the
  refund. The market itself checks every admission: it takes Patchbay's
  signature and refuses one made over any other value of each field.

  Left out of the default run. Start anvil as Base on this machine, then run
  this file alone:

      anvil --chain-id 8453 --host 127.0.0.1 --port 58621 --silent &
      mix test --only anvil test/patchbay/offers/market_lab_test.exs

  The contracts must be built first (`forge build` in contracts/).
  """

  use Patchbay.DataCase, async: false

  import PatchbayTest.OfferFixtures, only: [person!: 1]

  alias Patchbay.Offers
  alias Patchbay.Offers.{Admission, Board, Market, Node, Publisher, Scanner, Steps}
  alias PatchbayDev.OffersLab

  @moduletag :anvil
  @rpc_url "http://127.0.0.1:58621"
  @system %{role: :system}

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

    for wallet <- [accounts.advertiser, accounts.rival],
        do: Offers.set_advertiser_rule!(wallet, :accepted, actor: @system)

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

    Offers.set_advertiser_rule!(accounts.advertiser, :blocked, actor: @system)

    assert {:error, :blocked} =
             Admission.admit(advertiser, campaign, stripe.placement_id, 0, 5_000_000, 0)

    stranger = person!(OffersLab.accounts().payout)
    unknown = PatchbayTest.OfferFixtures.campaign!(stranger)

    assert {:error, :not_accepted} =
             Admission.admit(stranger, unknown, stripe.placement_id, 0, 5_000_000, 0)
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
