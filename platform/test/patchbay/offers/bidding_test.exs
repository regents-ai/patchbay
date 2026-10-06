defmodule Patchbay.Offers.BiddingTest do
  # Every bid moves Credits in the same transaction as the slot: held when
  # it is placed, carried over when it starts, given back in full when it
  # does not, and settled once when its Offer ends. Each test names the
  # money rule it protects. Not async: the removal test adds a moderator,
  # and the moderator list is shared by every test.
  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Patchbay.OffersFixtures

  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.BidWindow
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Placement
  alias RegentCredits.Errors.NotEnoughCredits

  setup do
    market = Offers.global_market!()
    %{market: market}
  end

  defp advertiser_with(credits, market, text) do
    profile = advertiser()
    give_credits(profile, credits)
    {profile, approved_version(profile, text, market)}
  end

  # Two seconds pass and the window's job runs.
  defp settle(market, number) do
    age(market, number, 2)

    # A test reads what it set up, so it skips policies deliberately.
    open = BidWindow |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.state == :open))

    Enum.each(open, fn window ->
      assert {:ok, _window} =
               perform_job(BidWindow.Workers.Settle, %{"primary_key" => %{"id" => window.id}})
    end)
  end

  defp reload(record), do: Ash.get!(record.__struct__, record.id, authorize?: false)

  defp placement_of(bid) do
    # A test reads back what it set up, so it skips policies deliberately.
    Placement |> Ash.read!(authorize?: false) |> Enum.find(&(&1.bid_id == bid.id))
  end

  test "an opening bid holds its Credits, then carries them to its placement", %{market: market} do
    {alice, version} = advertiser_with("10", market, "Alice fixes flaky builds.")

    assert {:ok, bid} = bid(alice, market, 1, version, "2.00")
    assert credits(alice) == %{available: "8", held: "2"}

    settle(market, 1)

    assert %Bid{status: :placed} = reload(bid)
    assert %Placement{status: :active, amount_minor: 200} = placement_of(bid)
    assert credits(alice) == %{available: "8", held: "2"}
  end

  test "in one window the highest bid wins and every other bid comes back in full",
       %{market: market} do
    {alice, alice_version} = advertiser_with("10", market, "Alice fixes flaky builds.")
    {bob, bob_version} = advertiser_with("10", market, "Bob ships faster deploys.")

    {:ok, alice_bid} = bid(alice, market, 1, alice_version, "2.00")
    {:ok, bob_bid} = bid(bob, market, 1, bob_version, "3.00")

    settle(market, 1)

    assert %Bid{status: :returned, return_reason: :outbid} = reload(alice_bid)
    assert %Bid{status: :placed} = reload(bob_bid)
    assert credits(alice) == %{available: "10", held: "0"}
    assert credits(bob) == %{available: "7", held: "3"}
  end

  test "a buyout returns the unused share and gives back the waiting next-period bid",
       %{market: market} do
    {alice, alice_version} = advertiser_with("40", market, "Alice fixes flaky builds.")
    {bob, bob_version} = advertiser_with("40", market, "Bob ships faster deploys.")
    {carol, carol_version} = advertiser_with("10", market, "Carol tunes slow queries.")

    {:ok, alice_bid} = bid(alice, market, 1, alice_version, "30.00")
    settle(market, 1)
    {:ok, carol_bid} = bid(carol, market, 1, carol_version, "5.00", lane: :next_period)
    settle(market, 1)
    assert %Bid{status: :leading} = reload(carol_bid)

    age(market, 1, 86_400)
    {:ok, _bob_bid} = bid(bob, market, 1, bob_version, "33.00")
    settle(market, 1)

    bought_out = placement_of(alice_bid)
    assert bought_out.status == :bought_out
    assert bought_out.forfeited_minor == 0
    # A day and a few seconds in: just under two thirds of 30 comes back.
    assert bought_out.returned_minor in 1999..2000
    assert bought_out.returned_minor + bought_out.consumed_minor == 3000

    back = bought_out.returned_minor |> Decimal.div(100) |> Decimal.add(10) |> Decimal.normalize()
    assert credits(alice) == %{available: Decimal.to_string(back, :normal), held: "0"}

    assert %Bid{status: :returned, return_reason: :cancelled_by_buyout} = reload(carol_bid)
    assert credits(carol) == %{available: "10", held: "0"}
    assert credits(bob) == %{available: "7", held: "33"}
  end

  test "when an Offer runs out, the waiting leader starts on the Credits already held",
       %{market: market} do
    {alice, alice_version} = advertiser_with("40", market, "Alice fixes flaky builds.")
    {carol, carol_version} = advertiser_with("10", market, "Carol tunes slow queries.")

    {:ok, alice_bid} = bid(alice, market, 1, alice_version, "30.00")
    settle(market, 1)
    {:ok, carol_bid} = bid(carol, market, 1, carol_version, "5.00", lane: :next_period)
    settle(market, 1)

    age(market, 1, 72 * 3600)
    expired = placement_of(alice_bid)

    assert {:ok, _placement} =
             perform_job(Placement.Workers.Expire, %{"primary_key" => %{"id" => expired.id}})

    assert %Placement{status: :expired, consumed_minor: 3000, returned_minor: 0} =
             reload(expired)

    assert credits(alice) == %{available: "10", held: "0"}
    assert %Bid{status: :placed} = reload(carol_bid)
    assert %Placement{status: :active} = placement_of(carol_bid)
    assert credits(carol) == %{available: "5", held: "5"}
  end

  test "a removal forfeits the unused share, starts the leader, and answers a repeat the same",
       %{market: market} do
    {alice, alice_version} = advertiser_with("40", market, "Alice fixes flaky builds.")
    {carol, carol_version} = advertiser_with("10", market, "Carol tunes slow queries.")
    moderator = moderator()

    {:ok, alice_bid} = bid(alice, market, 1, alice_version, "30.00")
    settle(market, 1)
    {:ok, carol_bid} = bid(carol, market, 1, carol_version, "5.00", lane: :next_period)
    settle(market, 1)
    age(market, 1, 86_400)

    showing = placement_of(alice_bid)

    request = %{
      placement_id: showing.id,
      expected_generation: showing.generation,
      reason: "Misleading claims",
      no_refund: true,
      idempotency_key: "remove-1"
    }

    assert {:ok, decision} = Offers.remove_placement(request, actor: moderator)
    assert decision.outcome == :removed
    assert decision.consumed_minor + decision.forfeited_minor == 3000
    assert decision.forfeited_minor in 1999..2000

    assert %Placement{status: :removed_for_policy, returned_minor: 0} = reload(showing)
    assert credits(alice) == %{available: "10", held: "0"}

    successor = placement_of(carol_bid)
    assert %Placement{status: :active} = successor
    assert decision.promoted_placement_id == successor.id
    assert credits(carol) == %{available: "5", held: "5"}

    assert {:ok, again} = Offers.remove_placement(request, actor: moderator)
    assert again.id == decision.id
    assert %Placement{status: :active} = reload(successor)
  end

  test "a bid the bidder can't cover leaves no bid and nothing held", %{market: market} do
    {alice, version} = advertiser_with("1", market, "Alice fixes flaky builds.")

    assert {:error, %Ash.Error.Invalid{errors: [%NotEnoughCredits{shortfall: shortfall}]}} =
             bid(alice, market, 1, version, "2.00")

    assert Decimal.eq?(shortfall, 1)
    assert Ash.read!(Bid, authorize?: false) == []
    assert Ash.read!(BidWindow, authorize?: false) == []
    assert credits(alice) == %{available: "1", held: "0"}
  end

  test "the same request key answers with its bid and never holds twice", %{market: market} do
    {alice, version} = advertiser_with("10", market, "Alice fixes flaky builds.")

    {:ok, first} = bid(alice, market, 1, version, "2.00", key: "press-1")
    {:ok, again} = bid(alice, market, 1, version, "2.00", key: "press-1")
    assert again.id == first.id
    assert credits(alice) == %{available: "8", held: "2"}

    assert {:error, %Ash.Error.Invalid{errors: [%BidRefused{reason: :key_reused}]}} =
             bid(alice, market, 1, version, "3.00", key: "press-1")
  end

  test "an agent signed in with its own wallet can't spend Credits yet", %{market: market} do
    {_alice, version} = advertiser_with("10", market, "Alice fixes flaky builds.")

    assert {:error, %Ash.Error.Invalid{errors: [%BidRefused{reason: :not_linked}]}} =
             bid(wallet_agent(), market, 1, version, "2.00")
  end
end
