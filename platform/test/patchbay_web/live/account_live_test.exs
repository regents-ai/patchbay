defmodule PatchbayWeb.AccountLiveTest do
  @moduledoc """
  Account's tabs: the inbox lives inside Account, beside the overview and
  the profile. The account menu's links lead here, on this site.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Identity

  test "the inbox opens inside Account, with what is waiting and what is followed", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:inbox",
        wallet_address: "0x" <> String.duplicate("e", 40)
      })

    conn = sign_in(conn, person.id)

    site = Forum.register_site!("followed.example.com")
    :ok = Forum.follow_site(person, Ash.UUID.generate(), site.id, true)

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

    # Stopping a follow changes the list where it stands; the page stays open.
    view |> element("#account-inbox button", "Stop following") |> render_click()

    refute has_element?(view, ~s(#account-inbox a[href="/#{site.origin}"]))
    assert render(view) =~ "You follow nothing yet."

    assert Forum.list_subscriptions_for_principals!([Forum.Principal.for_profile(person.id)],
             actor: %{principals: [Forum.Principal.for_profile(person.id)]}
           ) == []
  end

  test "a good agent name is saved in place, the new name in its field", %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:rename",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    conn = sign_in(conn, person.id)

    {:ok, view, _html} = live(conn, ~p"/account/profile")
    name = "renamed-#{System.unique_integer([:positive])}"

    view |> element(".pb-name-form") |> render_submit(%{"name" => name})

    assert has_element?(view, ~s(#pb-name-agent[value="#{name}"]))
    assert view |> element("#pb-account-problem") |> render() =~ ~r{>\s*</p>}
    assert Identity.get_profile!(person.id).agent_name == name
  end

  test "every link in the account menu lands on this site's Account or Agents page, on a part it has",
       %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:manage",
        wallet_address: "0x" <> String.duplicate("f", 40)
      })

    conn = sign_in(conn, person.id)

    page = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    # The wallet's own link opens it on the chain's explorer; every other link
    # stays on this site, in this tab. Pair New Agent is a button that opens the
    # pairing window.
    links = page |> LazyHTML.query(~s(#account-menu a[href^="/"])) |> LazyHTML.attribute("href")
    assert length(links) == 2
    assert page |> LazyHTML.query(~s(#account-menu a[href^="/"][target])) |> Enum.empty?()

    for link <- links do
      %URI{host: nil, path: path, fragment: fragment} = URI.parse(link)
      assert path in ["/account", "/account/agents"], link
      {:ok, view, _html} = live(conn, path)
      if fragment, do: assert(has_element?(view, "#" <> fragment), link)
    end
  end
end
