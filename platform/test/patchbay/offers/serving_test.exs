defmodule Patchbay.Offers.ServingTest do
  @moduledoc """
  Which paid offers go with a page or answer about a site, for one reader
  (`Patchbay.Offers.Serving`): each open placement's live leases in slot
  order, at most its capacity, only for campaigns Patchbay approved from
  wallets it accepts, in the placement's pools, sealed for this question and
  this reader; each shown once a day per page and reader, and no more pages
  a day than the campaign's limit. Nothing while no market is set.

  The moderator list is application-wide, so this file runs alone.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import PatchbayTest.OfferFixtures

  alias Patchbay.Offers
  alias Patchbay.Offers.Serving

  @system %{role: :system}
  @visitor %{kind: :visitor, id: "visitor-1", wallet: nil, evidence: []}

  setup do
    offers_on!()
    placement!(1, "stripe.com")
    advertiser = person!(wallet())
    %{advertiser: advertiser, campaign: shown_campaign!(advertiser)}
  end

  test "each open placement on the site, then each slot in order, at most its capacity", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    placement!(2, "stripe.com")
    placement!(3, "openai.com")
    second = shown_campaign!(advertiser, %{title: "Acme payouts"})

    lease!(2, 0, second)
    lease!(1, 2, second)
    lease!(1, 0, campaign)
    lease!(3, 0, campaign)
    # No slot past the placement's capacity of 3.
    lease!(1, 3, campaign)

    assert [{1, 0}, {1, 2}, {2, 0}] = shown(request())

    assert [%{campaign: %{title: "Acme payments"}, ends_at: %DateTime{}} | _rest] =
             serve(request())
  end

  test "a slot shows only its newest live lease", %{advertiser: advertiser, campaign: campaign} do
    buyout = shown_campaign!(advertiser, %{title: "Acme payouts"})
    lease!(1, 0, campaign, %{nonce: 1})
    lease!(1, 0, buyout, %{nonce: 2})

    ended = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    lease!(1, 1, campaign, %{starts_at: DateTime.add(ended, -3600), ends_at: ended})

    assert [%{slot: 0, campaign: %{title: "Acme payouts"}}] = serve(request())
  end

  test "only a campaign Patchbay approved is shown, and a pulled one is gone at once", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    waiting = campaign!(advertiser, %{title: "Acme payouts"})
    lease!(1, 0, campaign)
    lease!(1, 1, waiting)

    assert [{1, 0}] = shown(request())

    approve!(waiting)
    assert [{1, 0}, {1, 1}] = shown(request())

    Offers.pull_campaign!(campaign.campaign_id, %{reason: "Misleading"}, actor: moderator())
    assert [{1, 1}] = shown(request())
  end

  test "a blocked wallet is never shown, even when also accepted", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    lease!(1, 0, campaign)
    rule!(advertiser.wallet_address, :blocked)
    assert serve(request()) == []
  end

  test "a campaign is shown only with the questions and to the readers it sealed", %{
    advertiser: advertiser
  } do
    left_out = wallet()

    lease!(1, 0, shown_campaign!(advertiser, %{title: "Tagged", tags: ["payments"]}))
    lease!(1, 1, shown_campaign!(advertiser, %{title: "Help", kinds: [:help_needed]}))

    lease!(
      1,
      2,
      shown_campaign!(advertiser, %{
        title: "Paired",
        requires: [:paired],
        excluded_wallets: [left_out]
      })
    )

    question = request(%{task: %{tags: ["payments"], kind: :help_needed}})
    agent = %{kind: :agent, id: "agent-1", wallet: wallet(), evidence: [:paired]}

    # A site's page has no question; a visitor proved nothing.
    assert serve(request()) == []
    assert ["Tagged", "Help"] = titles(question, @visitor)
    assert ["Help"] = titles(request(%{task: %{tags: ["auth"], kind: :help_needed}}), @visitor)
    assert ["Tagged", "Help", "Paired"] = titles(question, agent)

    # The wallet the campaign leaves out, even proven.
    assert ["Tagged", "Help"] = titles(question, %{agent | wallet: left_out})
  end

  test "a placement shows from its chosen pools, else from General", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    lease!(1, 0, campaign)
    moderator = moderator()
    pool = Offers.create_pool!(%{name: "Payments", tags: []}, actor: moderator)
    Offers.add_pool_member!(pool.id, wallet(), actor: moderator)

    Offers.choose_pool!(
      %{chain_id: 8453, market: market(), placement_id: 1, pool_id: pool.id},
      actor: moderator
    )

    assert serve(request()) == []

    Offers.add_pool_member!(pool.id, advertiser.wallet_address, actor: moderator)
    assert [{1, 0}] = shown(request())

    # Another placement with no pools chosen shows from General.
    placement!(2, "stripe.com")
    lease!(2, 0, campaign)
    assert [{1, 0}, {2, 0}] = shown(request())
  end

  test "the same page read again by the same reader is the same delivery", %{campaign: campaign} do
    lease!(1, 0, campaign)

    [first] = serve(request())
    assert [%{delivery_id: same}] = serve(request())
    assert same == first.delivery_id

    [elsewhere] = serve(request(%{context: "/posts/1"}))
    [someone_else] = serve(request(), %{@visitor | id: "visitor-2"})

    assert length(Enum.uniq([first.delivery_id, elsewhere.delivery_id, someone_else.delivery_id])) ==
             3

    assert [delivery | _rest] = Ash.read!(Offers.Delivery, actor: @system)
    assert delivery.campaign_id == campaign.campaign_id
    assert delivery.delivered_on == Date.utc_today()
    assert length(Ash.read!(Offers.Delivery, actor: @system)) == 3
  end

  test "a daily limit counts the pages one reader was shown the campaign on today", %{
    advertiser: advertiser
  } do
    lease!(1, 0, shown_campaign!(advertiser, %{title: "Limited", daily_limit: 2}))

    assert [_shown] = serve(request(%{context: "/a"}))
    assert [_shown] = serve(request(%{context: "/b"}))
    assert serve(request(%{context: "/c"})) == []

    # A page already shown today shows it again; another reader has their own count.
    assert [_shown] = serve(request(%{context: "/a"}))
    assert [_shown] = serve(request(%{context: "/c"}), %{@visitor | id: "visitor-2"})
  end

  test "while no market is set, or the answer is about no site, nothing is read or shown", %{
    campaign: campaign
  } do
    lease!(1, 0, campaign)
    assert serve(request(%{site: nil})) == []

    offers_on!(market_address: nil)
    assert serve(request()) == []
    assert Ash.read!(Offers.Delivery, actor: @system) == []
  end

  defp request(attrs \\ %{}) do
    Map.merge(
      %{site: "stripe.com", task: %{tags: [], kind: nil}, surface: :page, context: "/stripe.com"},
      attrs
    )
  end

  defp serve(request, reader \\ @visitor), do: Serving.serve(request, reader)
  defp shown(request), do: Enum.map(serve(request), &{&1.placement_id, &1.slot})
  defp titles(request, reader), do: Enum.map(serve(request, reader), & &1.campaign.title)
end
