defmodule PatchbayWeb.OffersLive.BidTest do
  # The bid page for one site slot: a signed-in advertiser sees their
  # Credits, bids with an approved wording,
  # holds the full amount, hears when they are outbid, and can bid again
  # once the slot has moved on.
  #
  # Not async: settling a window runs the same job every Offers test uses.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures
  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Offers

  setup do
    {:ok, site} =
      Forum.register_site("bid-#{System.unique_integer([:positive])}.example",
        authorize?: false
      )

    market = Offers.open_site_market!(site.id, authorize?: false)
    owner = advertiser()
    give_credits(owner, "10")
    version = approved_version(owner, "Owner fixes flaky builds.", market)

    %{
      market: market,
      owner: owner,
      version: version,
      path: "/offers/bid?site=#{site.id}&slot=1"
    }
  end

  test "a bid holds its Credits; outbid, it comes back, and Bid again is a new bid",
       %{conn: conn, market: market, owner: owner, version: version, path: path} do
    {:ok, view, _html} = conn |> signed_in(owner) |> live(path)
    assert view |> element("#pb-offers-bid-balance") |> render() =~ "10"

    bid!(view, version, "2.00")
    assert credits(owner) == %{available: "8", held: "2"}
    assert has_element?(view, "#pb-offers-bid-mine-list", "Pending")

    rival = advertiser()
    give_credits(rival, "10")
    assert {:ok, _bid} = bid(rival, market, 1, approved_version(rival, "Rival", market), "3.00")
    settle(market, 1)
    render(view)

    assert has_element?(view, "#pb-offers-outbid", "You were outbid and Credits are returned")
    assert credits(owner) == %{available: "10", held: "0"}

    # The same details against the slot as it stands now: a new bid, judged on
    # the new price, never the earlier request.
    assert bid!(view, version, "2.00") =~ "This bid needs to be at least 3.30 Credits."
    assert credits(owner) == %{available: "10", held: "0"}
  end

  test "once your own bid is showing, Bid again with the same details is a new bid",
       %{conn: conn, market: market, owner: owner, version: version, path: path} do
    {:ok, view, _html} = conn |> signed_in(owner) |> live(path)

    bid!(view, version, "2.00")
    settle(market, 1)
    render(view)
    assert has_element?(view, "#pb-offers-bid-mine-list", "Won")

    assert bid!(view, version, "2.00") =~ "This bid needs to be at least 2.20 Credits."
    assert credits(owner) == %{available: "8", held: "2"}
  end

  defp bid!(view, version, amount) do
    view
    |> form("#pb-offers-bid-form",
      bid: %{lane: "immediate", version_id: version.id, amount: amount}
    )
    |> render_submit()
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end
end
