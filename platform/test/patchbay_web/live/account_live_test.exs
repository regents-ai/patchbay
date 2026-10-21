defmodule PatchbayWeb.AccountLiveTest do
  @moduledoc """
  Account's tabs: the inbox lives inside Account, beside the overview and
  the profile. The side panel's Manage links lead here, on this site.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  test "the inbox opens inside Account, with what is waiting and what is followed", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:inbox",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
    site = Forum.register_site!("followed.example.com")

    assert conn
           |> post(~p"/follow", %{
             "site_id" => site.id,
             "follow" => "true",
             "back" => "/account/inbox"
           })
           |> redirected_to() == "/account/inbox"

    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: "Where does the basket go?",
        thread_kind: :help_needed,
        body_markdown: "Asked on the board."
      },
      authorize?: false
    )

    Forum.NotificationFanout.process_events()

    {:ok, view, html} = live(conn, ~p"/account/inbox")

    assert html =~ ~s(href="/account/inbox" aria-current="page")
    assert has_element?(view, "#account-inbox")
    assert render(view) =~ "Where does the basket go?"
    assert has_element?(view, ~s(#account-inbox a[href="/#{site.origin}"]))

    view |> element("#account-inbox button", "Acknowledge") |> render_click()

    refute render(view) =~ "Where does the basket go?"
    assert render(view) =~ "Nothing waiting."
  end

  test "the side panel's Manage links open this site's Account page and its agents", %{
    conn: conn
  } do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:manage",
        wallet_address: "0x" <> String.duplicate("f", 40)
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
    page = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert ["/account"] ==
             page |> LazyHTML.query("#shell-aside a.rg-button") |> LazyHTML.attribute("href")

    assert page |> LazyHTML.query("#shell-aside a[target]") |> Enum.empty?()

    assert ["/account#account-agents"] ==
             page
             |> LazyHTML.query(~s(#shell-aside a[href^="/account#"]))
             |> LazyHTML.attribute("href")

    {:ok, view, _html} = live(conn, ~p"/account")
    assert has_element?(view, "#account-agents")
  end
end
