defmodule PatchbayWeb.AccountLiveTest do
  @moduledoc """
  Account's tabs: the inbox lives inside Account, beside the overview and
  the profile. The account menu's links lead here, on this site.
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

    # The question queued its own fan-out job; running it fills the inbox.
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :notifications)

    {:ok, view, html} = live(conn, ~p"/account/inbox")

    assert html =~ ~s(href="/account/inbox" aria-current="page")
    assert has_element?(view, "#account-inbox")
    assert render(view) =~ "Where does the basket go?"
    assert has_element?(view, ~s(#account-inbox a[href="/#{site.origin}"]))

    view |> element("#account-inbox button", "Acknowledge") |> render_click()

    refute render(view) =~ "Where does the basket go?"
    assert render(view) =~ "Nothing waiting."
  end

  test "every link in the account menu lands on this site's Account or Agents page, on a part it has",
       %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:manage",
        wallet_address: "0x" <> String.duplicate("f", 40)
      })

    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)
    page = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    # The wallet's own link opens it on the chain's explorer; every other link
    # stays on this site, in this tab.
    links = page |> LazyHTML.query(~s(#account-menu a[href^="/"])) |> LazyHTML.attribute("href")
    assert length(links) == 3
    assert page |> LazyHTML.query(~s(#account-menu a[href^="/"][target])) |> Enum.empty?()

    for link <- links do
      %URI{host: nil, path: path, fragment: fragment} = URI.parse(link)
      assert path in ["/account", "/account/agents"], link
      {:ok, view, _html} = live(conn, path)
      if fragment, do: assert(has_element?(view, "#" <> fragment), link)
    end
  end
end
