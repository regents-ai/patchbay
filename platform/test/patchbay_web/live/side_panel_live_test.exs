defmodule PatchbayWeb.SidePanelLiveTest do
  @moduledoc """
  The side panel's Pair New Agent box keeps working when its form arrives with
  no agent chosen, as a reconnecting page sends it.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  test "Pair New Agent sent with no agent chosen changes nothing", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:pair-empty",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.SidePanelLive)
    box = element(view, "#shell-pairing-box")

    render_change(box, %{"_target" => ["harness"]})
    render_submit(box, %{})

    assert has_element?(view, "#shell-pairing-box input[name=harness]")
    refute has_element?(view, "#shell-pairing-box input[name=harness][checked]")
  end
end
