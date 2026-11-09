defmodule PatchbayWeb.HeaderAccountLiveTest do
  @moduledoc """
  When the sign-in the account menu was drawn with has run out, the menu shows
  nothing and leaves the page around it where it is, instead of failing to join
  and reloading the page.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity

  test "a sign-in that has run out shows no menu and keeps the page", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:lapsed-header",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    lapsed = %{"agent_profile_id" => person.id, "signed_in_at" => 0, "site_edition" => :main}

    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.HeaderAccountLive, session: lapsed)

    send(view.pid, :agents_changed)
    refute has_element?(view, "#account-menu")
  end
end
