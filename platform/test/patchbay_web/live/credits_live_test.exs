defmodule PatchbayWeb.CreditsLiveTest do
  @moduledoc """
  The header's Credits balance when the sign-in it was drawn with has run out:
  it shows nothing and leaves the page around it where it is, instead of
  failing to join and reloading the page.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity

  test "a sign-in that has run out shows no balance and keeps the page", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:credits-header",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    lapsed = %{"agent_profile_id" => person.id, "signed_in_at" => 0}

    {:ok, view, html} = live_isolated(conn, PatchbayWeb.CreditsLive, session: lapsed)

    refute html =~ "pb-credits-balance"
    send(view.pid, :credits_changed)
    refute render(view) =~ "pb-credits-balance"
  end
end
