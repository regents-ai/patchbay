defmodule PatchbayWeb.HeaderAccountLiveTest do
  @moduledoc """
  The header's Credits balance and account menu when the sign-in they were drawn
  with has run out: they show nothing and leave the page around them where it
  is, instead of failing to join and reloading the page.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity

  test "a sign-in that has run out shows no balance or menu and keeps the page", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:credits-header",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    lapsed = %{"agent_profile_id" => person.id, "signed_in_at" => 0, "site_edition" => :main}

    {:ok, view, html} = live_isolated(conn, PatchbayWeb.HeaderAccountLive, session: lapsed)

    refute html =~ "pb-credits-balance"
    send(view.pid, :credits_changed)
    send(view.pid, :agents_changed)
    refute has_element?(view, "#pb-credits-balance")
    refute has_element?(view, "#account-menu")
  end
end
