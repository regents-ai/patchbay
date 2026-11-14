defmodule PatchbayWeb.OffersLiveTest do
  @moduledoc """
  The `/offers` page (`PatchbayWeb.OffersLive`) against a chain the test holds
  (`PatchbayTest.OfferChain`): the board from Patchbay's record, campaigns
  written from the form, and the Buy and Claim buttons, disabled only when the
  chain at the latest block makes a press certain to fail. Every other press
  reaches the wallet, a repeat one too.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PatchbayTest.OfferFixtures

  alias Patchbay.Offers
  alias Patchbay.Offers.Contract
  alias PatchbayDev.OffersLab
  alias PatchbayTest.OfferChain, as: Chain

  @moduletag :capture_log
  @system %{role: :system}

  setup do
    offers_on!(client: Chain, publisher_private_key: OffersLab.publisher_key())
    Chain.start!()
    %{placement: placement!(1, "stripe.com")}
  end

  test "while no market is set, the page is not there", %{conn: conn} do
    offers_on!(market_address: nil)
    assert_error_sent 404, fn -> get(conn, ~p"/offers") end
  end

  describe "the board" do
    setup do
      owner = person!(wallet())
      %{campaign: campaign!(owner)}
    end

    test "shows each slot's offer, what it paid and the least the next purchase pays", %{
      conn: conn,
      campaign: campaign
    } do
      lease!(1, 0, campaign, %{paid_usdc: Decimal.new(12_000_000)})
      {:ok, view, _html} = live(conn, ~p"/offers")

      shown = view |> element("#placement-1-slot-0") |> render()
      assert shown =~ ~s(href="#{campaign.link}")
      assert shown =~ "12.00 USDC"
      assert shown =~ "13.20 USDC"

      assert has_element?(view, "#placement-1-slot-1[data-open]")
      assert view |> element("#placement-1-slot-1") |> render() =~ "5.00 USDC"
      refute has_element?(view, "#placement-1-slot-3")
    end

    test "signed out, Buy asks the person to sign in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/offers")

      assert has_element?(view, "#placement-1-slot-0 button[data-account-target=sign-in]")
      refute has_element?(view, "#placement-1-slot-0 a[href*='placement=1']")
      assert has_element?(view, "#offers-signed-out")
      refute has_element?(view, "#offers-new-campaign")
    end

    test "while buying is closed, the page says so and shows no Buy", %{conn: conn} do
      offers_on!(publisher_private_key: nil)
      {:ok, view, _html} = live(conn, ~p"/offers")

      assert has_element?(view, "#offers-closed")
      refute has_element?(view, ".pb-slot-action")
    end
  end

  test "a signed-in person writes a campaign from the form, and it is listed as theirs", %{
    conn: conn
  } do
    person = person!(wallet())
    {:ok, view, _html} = conn |> sign_in(person.id) |> live(~p"/offers")
    form = "#offers-new-campaign"

    view |> element(form) |> render_change(%{"campaign" => %{"audience" => "sites"}})

    view
    |> form(form, %{
      "campaign" => %{
        "title" => "Acme payments",
        "body" => "Take card payments in one line of code.",
        "link" => "https://acme.example/agents",
        "audience" => "sites",
        "sites" => "stripe.com, https://www.openai.com/pricing"
      }
    })
    |> render_submit()

    assert [campaign] = Offers.my_campaigns!(actor: person)
    assert campaign.advertiser == person.wallet_address
    assert campaign.sites == ["openai.com", "stripe.com"]
    assert has_element?(view, "#campaign-#{campaign.id}[data-new]")
  end

  describe "Buy" do
    setup %{conn: conn} do
      person = person!(wallet())
      campaign = campaign!(person)
      %{person: person, campaign: campaign, conn: sign_in(conn, person.id)}
    end

    test "a campaign Patchbay will not admit shows why in place of the buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/offers?placement=1&slot=0")

      assert has_element?(view, "#offers-buy")
      assert has_element?(view, "#offers-buy-refusal")
      refute has_element?(view, "#offers-buy [data-onchain-step]")
    end

    test "is disabled only when the chain makes it certain to fail, and every other press is sent",
         %{conn: conn, person: person, campaign: campaign, placement: placement} do
      Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: @system)
      open_slot!(placement, 0, 5_000_000, 0)
      Chain.usdc!(person.wallet_address, 20_000_000, 0)

      {:ok, view, _html} = live(conn, ~p"/offers?placement=1&slot=0")
      render_async(view)

      # No approval on the chain yet: Approve is sent, and sent again.
      assert buy_disabled?(view)
      refute has_element?(view, "#offers-buy [data-onchain-step=approve][disabled]")

      for _press <- 1..2 do
        press(view, person, campaign, "approve", "5.00")
        assert_reply(view, %{send: "approve", review: %{}})
      end

      # The approval lands.
      Chain.usdc!(person.wallet_address, 20_000_000, 5_000_000)
      landed(view)

      refute buy_disabled?(view)

      for _press <- 1..2 do
        press(view, person, campaign, "buy", "5.00")
        assert_reply(view, %{send: "buy", review: %{}})
      end

      # Below the slot's minimum, or more than the wallet holds.
      for amount <- ["4.99", "25.00"] do
        view |> element("#offers-buy-form") |> render_change(%{"amount" => amount})
        assert buy_disabled?(view)
      end
    end

    test "a press from another wallet than the campaign's is not sent", %{
      conn: conn,
      person: person,
      campaign: campaign,
      placement: placement
    } do
      Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: @system)
      open_slot!(placement, 0, 5_000_000, 0)
      Chain.usdc!(person.wallet_address, 20_000_000, 0)

      {:ok, view, _html} = live(conn, ~p"/offers?placement=1&slot=0")
      press(view, %{wallet_address: wallet()}, campaign, "approve", "5.00")
      assert_reply(view, reply)
      refute Map.has_key?(reply, :send)
    end
  end

  describe "Claim" do
    setup %{conn: conn} do
      person = person!(wallet())
      %{person: person, conn: sign_in(conn, person.id)}
    end

    test "is disabled only when the chain says there is nothing to claim", %{
      conn: conn,
      person: person
    } do
      wallet = person.wallet_address
      claim = "#offers-claim-#{wallet}"

      Chain.answer_read!(Contract.claimable(wallet), [0])
      {:ok, view, _html} = live(conn, ~p"/offers")
      render_async(view)
      assert has_element?(view, "#{claim} [data-onchain-step=claim][disabled]")

      Chain.answer_read!(Contract.claimable(wallet), [1_250_000])
      landed(view)
      refute has_element?(view, "#{claim} [data-onchain-step=claim][disabled]")

      # The page's hook sends each press to its own panel.
      view
      |> with_target(claim)
      |> render_hook("prepare_and_send", %{"step" => "claim", "address" => wallet})

      assert_reply(view, %{send: "claim", review: %{}})
    end

    test "a wallet that could not be read is never held back", %{conn: conn, person: person} do
      {:ok, view, _html} = live(conn, ~p"/offers")
      render_async(view)

      refute has_element?(
               view,
               "#offers-claim-#{person.wallet_address} [data-onchain-step=claim][disabled]"
             )
    end
  end

  # A slot with no lease, in an open placement, at `minimum`, as the market
  # reads at the latest block.
  defp open_slot!(placement, slot, minimum, nonce) do
    id = placement.placement_id
    zero = <<0::256>>

    Chain.answer_read!(Contract.minimum_price(id, slot), [minimum])
    Chain.answer_read!(Contract.get_lease(id, slot), [{<<0::160>>, zero, 0, 0, 0, nonce}])

    Chain.answer_read!(Contract.get_placement(id), [
      {bytes(placement.source_id),
       {placement.capacity, placement.duration_seconds, placement.min_bump_bps,
        Decimal.to_integer(placement.floor_usdc), bytes(placement.policy_hash)}, 0}
    ])
  end

  defp press(view, person, campaign, step, amount) do
    view
    |> with_target("#offers-buy")
    |> render_hook("prepare_and_send", %{
      "step" => step,
      "form" => %{"campaign" => campaign.id, "amount" => amount},
      "address" => person.wallet_address
    })
  end

  # A step lands: the page hears of it and tells each panel, which reads the
  # chain again. The first render lets the page pass the word on before the
  # wait for the panels' reads.
  defp landed(view) do
    send(view.pid, {PatchbayWeb.OnchainSteps, :landed, 8453})
    _heard = render(view)
    render_async(view)
  end

  defp buy_disabled?(view),
    do: has_element?(view, "#offers-buy [data-onchain-step=buy][disabled]")

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
end
