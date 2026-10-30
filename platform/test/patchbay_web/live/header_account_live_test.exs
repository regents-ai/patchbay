defmodule PatchbayWeb.HeaderAccountLiveTest do
  @moduledoc """
  The account menu's Credits balance follows a change to the person's Credits,
  and when the sign-in the menu was drawn with has run out, the menu shows
  nothing and leaves the page around it where it is, instead of failing to join
  and reloading the page.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Patchbay.OffersFixtures

  alias Patchbay.Identity

  test "the menu's balance shows a change to the person's Credits", %{conn: conn} do
    person = advertiser()

    session = %{
      "agent_profile_id" => person.id,
      "signed_in_at" => System.system_time(:second),
      "site_edition" => :main
    }

    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.HeaderAccountLive, session: session)
    render_async(view)
    assert has_element?(view, "#account-menu-credits [data-count]", "0")

    give_credits(person, "12.4")
    send(view.pid, :credits_changed)
    render_async(view)
    assert has_element?(view, "#account-menu-credits[aria-label='12.40 Credits']")
  end

  test "a sign-in that has run out shows no balance or menu and keeps the page", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:credits-header",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    lapsed = %{"agent_profile_id" => person.id, "signed_in_at" => 0, "site_edition" => :main}

    {:ok, view, html} = live_isolated(conn, PatchbayWeb.HeaderAccountLive, session: lapsed)

    refute html =~ "account-menu-credits"
    send(view.pid, :credits_changed)
    send(view.pid, :agents_changed)
    refute has_element?(view, "#account-menu-credits")
    refute has_element?(view, "#account-menu")
  end
end
