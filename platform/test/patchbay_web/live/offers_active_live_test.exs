defmodule PatchbayWeb.OffersLive.ActiveTest do
  # The advertiser's Active and History tabs: an open Active tab follows a
  # bid to its result without a reload, an Offer whose time is up stays in
  # Active until it moves to History, and History signed out stays a
  # sign-in prompt whatever the page is sent.
  #
  # Not async: settling a window runs the same job every Offers test uses.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures
  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Offers

  setup do
    origin = "active-#{System.unique_integer([:positive])}.example"
    {:ok, site} = Forum.register_site(origin, authorize?: false)
    %{origin: origin, market: Offers.open_site_market!(site.id, authorize?: false)}
  end

  test "an open Active tab shows a bid's result as soon as it is known",
       %{conn: conn, origin: origin, market: market} do
    owner = advertiser()
    give_credits(owner, "10")
    version = approved_version(owner, "Owner fixes flaky builds.", market)

    {:ok, view, _html} = conn |> signed_in(owner) |> live("/offers/active")
    refute has_element?(view, "#pb-offers-mine-showing-list .pb-placement-card", origin)

    assert {:ok, _bid} = bid(owner, market, 1, version, "2.00")
    settle(market, 1)

    assert has_element?(view, "#pb-offers-mine-showing-list .pb-placement-card", origin)
  end

  test "an Offer whose time is up stays in Active until it moves to History",
       %{conn: conn, origin: origin, market: market} do
    owner = advertiser()

    place(market, 1, approved_version(owner, "Ran its time", market),
      starts_at: DateTime.add(DateTime.utc_now(), -73, :hour)
    )

    {:ok, view, _html} = conn |> signed_in(owner) |> live("/offers/active")
    assert has_element?(view, "#pb-offers-mine-showing-list .pb-placement-card", origin)
    assert view |> element("#pb-offers-mine-showing-list") |> render() =~ "100% fulfilled"
  end

  test "signed out, History stays a sign-in prompt when asked for more", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/offers/history")
    assert render_hook(view, "more", %{"list" => "ended"}) =~ "Sign in to see your past Offers."
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end
end
