defmodule PatchbayWeb.OffersAdminLiveTest do
  @moduledoc """
  Patchbay's side of agent offers at `/admin/offers`
  (`PatchbayWeb.OffersAdminLive`): a moderator approves and pulls campaigns,
  accepts and blocks wallets, keeps pools and chooses them per placement,
  each in place, and reads the steps that refund a pulled campaign's leases.
  Anyone else is answered as though the page does not exist, and every action
  behind a press refuses them whatever page they came from. The page is
  there only at patchbay.help while a market is set.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import Phoenix.LiveViewTest
  import PatchbayTest.OfferFixtures

  alias Patchbay.Offers

  @path "/admin/offers"

  setup do
    offers_on!()
    placement!(1, "stripe.com")
    advertiser = person!(wallet())
    rule!(advertiser.wallet_address)
    %{advertiser: advertiser, campaign: campaign!(advertiser)}
  end

  test "is not there for a visitor or a signed-in person, at the open address, or with no market",
       %{conn: conn, advertiser: advertiser} do
    assert_error_sent 404, fn -> get(conn, @path) end
    assert_error_sent 404, fn -> conn |> sign_in(advertiser.id) |> get(@path) end

    moderator = moderator()
    assert conn |> sign_in(moderator.id) |> get(@path) |> html_response(200) =~ "pb-offers-admin"
    assert_error_sent 404, fn -> conn |> on_open() |> sign_in(moderator.id) |> get(@path) end

    offers_on!(market_address: nil)
    assert_error_sent 404, fn -> conn |> sign_in(moderator.id) |> get(@path) end
  end

  test "a moderator approves and pulls a campaign in place, and reads the refund steps", %{
    conn: conn,
    campaign: campaign
  } do
    lease!(1, 2, campaign)
    {:ok, view, _html} = conn |> sign_in(moderator().id) |> live(@path)
    row = "#pb-oa-campaign-#{campaign.id}"

    assert has_element?(view, "#{row}[data-review=waiting]")
    view |> element("#pb-oa-approve-#{campaign.id}") |> render_click()
    assert has_element?(view, "#{row}[data-review=approved]")
    refute has_element?(view, "#pb-oa-approve-#{campaign.id}")

    view |> form("#pb-oa-pull-#{campaign.id}", %{"reason" => "Misleading"}) |> render_submit()
    assert has_element?(view, "#{row}[data-review=pulled]")

    steps = view |> element("#pb-oa-refund-#{campaign.id}") |> render()
    assert steps =~ "terminatePlacement"
    assert steps =~ "settleTerminated"
    assert steps =~ "slot 3, number 2 on Base"

    assert [%{decision: :approved}, %{decision: :pulled, reason: "Misleading"}] =
             Enum.sort_by(Offers.list_reviews!(), & &1.decision)
  end

  test "a moderator accepts, blocks and removes advertiser wallets in place", %{conn: conn} do
    {:ok, view, _html} = conn |> sign_in(moderator().id) |> live(@path)
    held = wallet()

    view
    |> form("#pb-oa-rule", %{"wallet" => String.upcase(held)})
    |> render_submit(%{"verdict" => "blocked"})

    assert [%{wallet: ^held, verdict: :blocked} = rule] = rules(held)
    assert has_element?(view, "#pb-oa-rule-#{rule.id}")

    view
    |> form("#pb-oa-rule", %{"wallet" => "not a wallet"})
    |> render_submit(%{"verdict" => "accepted"})

    assert has_element?(view, "#pb-oa-problem", "Use a wallet address")

    view |> element("#pb-oa-rule-#{rule.id} .pb-oa-remove") |> render_click()
    refute has_element?(view, "#pb-oa-rule-#{rule.id}")
    assert rules(held) == []
  end

  test "a moderator keeps pools and their members, and chooses them per placement", %{
    conn: conn,
    advertiser: advertiser,
    campaign: campaign
  } do
    approve!(campaign)
    lease!(1, 0, campaign)
    {:ok, view, _html} = conn |> sign_in(moderator().id) |> live(@path)
    placement = "#pb-oa-placement-1"

    assert view |> element("#{placement} .pb-oa-pools-chosen") |> render() =~ "General"

    view
    |> form("#pb-oa-new-pool", %{"name" => "Payments", "tags" => "Payments, auth"})
    |> render_submit()

    assert [pool] = Offers.list_pools!(actor: moderator())
    assert pool.tags == ["payments", "auth"]

    view
    |> form("#pb-oa-add-member-#{pool.id}", %{"wallet" => advertiser.wallet_address})
    |> render_submit()

    assert [member] = Offers.get_pool!(pool.id, actor: moderator(), load: [:members]).members
    assert has_element?(view, "#pb-oa-member-#{member.id}")

    view |> form("#pb-oa-choose-1", %{"pool_id" => pool.id}) |> render_submit()
    assert [choice] = Offers.placement_pools!(8453, market(), [1], actor: moderator())
    assert has_element?(view, "#pb-oa-choice-#{choice.id}", "Payments")
    refute view |> element("#{placement} .pb-oa-pools-chosen") |> render() =~ "General"

    # The lease and how often it was shown.
    assert view |> element(placement) |> render() =~ campaign.title

    view |> element("#pb-oa-choice-#{choice.id} button") |> render_click()
    assert view |> element("#{placement} .pb-oa-pools-chosen") |> render() =~ "General"

    view |> element("#pb-oa-member-#{member.id} .pb-oa-remove") |> render_click()
    refute has_element?(view, "#pb-oa-member-#{member.id}")

    view |> element("#pb-oa-pool-#{pool.id} .pb-oa-remove") |> render_click()
    refute has_element?(view, "#pb-oa-pool-#{pool.id}")
    assert Offers.list_pools!(actor: moderator()) == []
  end

  test "a moderator lets a stopped reading of the market go on", %{conn: conn} do
    system = %{role: :system}

    cursor =
      Offers.open_cursor!(%{chain_id: 8453, market: market(), next_block: 10}, actor: system)

    Offers.stop_cursor!(cursor, 12, actor: system)

    {:ok, view, _html} = conn |> sign_in(moderator().id) |> live(@path)
    assert has_element?(view, "#pb-oa-reading")

    view |> form("#pb-oa-clear", %{"next_block" => "12"}) |> render_submit()
    refute has_element?(view, "#pb-oa-reading")
    assert %{rescan_from: nil, next_block: 12} = Offers.get_cursor!(8453, market())
  end

  test "every action behind a press refuses anyone but a moderator", %{
    advertiser: advertiser,
    campaign: campaign
  } do
    moderator = moderator()
    system = %{role: :system}
    rule = Offers.set_advertiser_rule!(wallet(), :accepted, actor: moderator)
    pool = Offers.create_pool!(%{name: "Payments", tags: []}, actor: moderator)
    member = Offers.add_pool_member!(pool.id, wallet(), actor: moderator)
    choice = %{chain_id: 8453, market: market(), placement_id: 1, pool_id: pool.id}
    chosen = Offers.choose_pool!(choice, actor: moderator)

    cursor =
      Offers.open_cursor!(%{chain_id: 8453, market: market(), next_block: 10}, actor: system)

    presses = [
      fn actor -> Offers.approve_campaign(campaign.campaign_id, actor: actor) end,
      fn actor -> Offers.pull_campaign(campaign.campaign_id, actor: actor) end,
      fn actor -> Offers.set_advertiser_rule(wallet(), :blocked, actor: actor) end,
      fn actor -> Offers.remove_advertiser_rule(rule, actor: actor) end,
      fn actor -> Offers.create_pool(%{name: "Other", tags: []}, actor: actor) end,
      fn actor -> Offers.delete_pool(pool, actor: actor) end,
      fn actor -> Offers.add_pool_member(pool.id, wallet(), actor: actor) end,
      fn actor -> Offers.remove_pool_member(member, actor: actor) end,
      fn actor -> Offers.choose_pool(%{choice | placement_id: 2}, actor: actor) end,
      fn actor -> Offers.drop_pool(chosen, actor: actor) end,
      fn actor -> Offers.clear_cursor(cursor, %{next_block: 10}, actor: actor) end
    ]

    for press <- presses, actor <- [advertiser, system, nil] do
      assert {:error, %Ash.Error.Forbidden{}} = press.(actor)
    end
  end

  test "a page left open after its moderator leaves the list does nothing more", %{
    conn: conn,
    campaign: campaign
  } do
    moderator = moderator()

    for {event, params} <- [
          {"approve", %{"campaign_id" => campaign.campaign_id}},
          {"pull", %{"campaign_id" => campaign.campaign_id, "reason" => "x"}},
          {"set_rule", %{"wallet" => wallet(), "verdict" => "blocked"}},
          {"create_pool", %{"name" => "Payments", "tags" => ""}}
        ] do
      {:ok, view, _html} = conn |> sign_in(moderator.id) |> live(@path)
      listed = Application.get_env(:patchbay, :moderator_wallets)
      Application.put_env(:patchbay, :moderator_wallets, listed -- [moderator.wallet_address])

      assert {:error, {:redirect, %{to: "/"}}} = render_click(view, event, params)
      Application.put_env(:patchbay, :moderator_wallets, listed)
    end

    assert Offers.list_reviews!() == []
    assert Offers.list_pools!(actor: moderator) == []
  end

  defp rules(wallet),
    do: Offers.advertiser_rules!([wallet], actor: %{role: :system})
end
