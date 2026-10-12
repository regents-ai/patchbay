defmodule PatchbayWeb.OffersLive.CreateTest do
  # The advertiser's page checks a wording with the same rule the save
  # applies, saves it for screening, keeps every wording as its own version,
  # and shows each advertiser only their own Offers.
  use PatchbayWeb.ConnCase, async: true

  import Patchbay.OffersFixtures
  import Phoenix.LiveViewTest

  alias Patchbay.Offers

  test "a visitor who is not signed in is told how to start", %{conn: conn} do
    {:ok, view, html} = live(conn, "/offers/create")
    assert html =~ "Sign in at the top of the page to save an Offer."
    refute has_element?(view, "#pb-offers-new-form")
  end

  test "a wording is checked as typed, saved for screening, and changed as a new version",
       %{conn: conn} do
    owner = advertiser()
    {:ok, _theirs} = Offers.create_creative("Theirs", "Someone else's Offer", actor: advertiser())
    {:ok, view, _html} = conn |> signed_in(owner) |> live("/offers/create")

    checked =
      view
      |> form("#pb-offers-new-form",
        offer: %{label: "Launch", text: "Try https://a.dev or b.dev"}
      )
      |> render_change()

    assert checked =~ "26 of 160 characters · 26 of 640 bytes"
    assert checked =~ "Links screening will visit: https://a.dev"
    assert checked =~ "Not written as a full link, so a person checks it: b.dev"
    assert checked =~ "Site · Slot 1 (until "
    assert checked =~ "&quot;Try https://a.dev or b.dev&quot;"

    too_long = String.duplicate("é", 161)

    assert view
           |> form("#pb-offers-new-form", offer: %{label: "Long", text: too_long})
           |> render_submit() =~ "The wording is longer than 160 characters."

    saved =
      view
      |> form("#pb-offers-new-form",
        offer: %{label: "Launch", text: "Try https://a.dev or b.dev"}
      )
      |> render_submit()

    assert saved =~ "Launch"
    assert saved =~ "Safety:</strong> Waiting for screening."
    refute saved =~ "Someone else&#39;s Offer"
    assert [%{label: "Launch"} = creative] = Offers.my_creatives!(actor: owner)

    view |> element("#pb-offers-saved-#{creative.id} button", "Change wording") |> render_click()

    reworded =
      view
      |> form("#pb-offers-reword-#{creative.id}", reword: %{text: "Try https://a.dev today"})
      |> render_submit()

    assert reworded =~ "Version 2"
    assert reworded =~ "Earlier versions"
    assert reworded =~ "Try https://a.dev today"
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end
end
