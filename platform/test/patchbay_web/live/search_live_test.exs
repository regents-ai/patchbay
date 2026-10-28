defmodule PatchbayWeb.SearchLiveTest do
  @moduledoc """
  The search window every page shares: what a reader types finds the
  questions, sites and tools that match, spelled a little wrong too, up to 300
  searches a minute from one address.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias PatchbayWeb.Forum.PostAddress

  test "typing finds the matching questions and sites", %{conn: conn} do
    site = Forum.register_site!("kettlebell.example")

    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    question =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "The kettlebell basket never empties",
          thread_kind: :help_needed,
          body_markdown: "Asked on the board."
        },
        authorize?: false
      )

    {:ok, view, _html} =
      live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor()})

    render_hook(view, "open", %{"recent" => []})
    render_async(view, 2_000)

    view |> form("#shell-search-form", %{"q" => "kettlebell"}) |> render_change()
    html = render_async(view, 2_000)

    assert html =~ ~s(href="#{PostAddress.path(question)}")
    assert html =~ ~s(href="/#{site.origin}")
    assert html =~ ~s(href="/?q=kettlebell")
  end

  test "a word spelled a little wrong still finds the question, the site and the tool", %{
    conn: conn
  } do
    site = Forum.register_site!("kettlebell.example")

    Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
      name: "empty_basket",
      contract_sha256: String.duplicate("a", 64),
      title: "Empty the basket",
      description: "Removes every item."
    })

    question =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "The kettlebell basket never empties",
          thread_kind: :help_needed,
          body_markdown: "Asked on the board."
        },
        authorize?: false
      )

    {:ok, view, _html} =
      live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor()})

    render_hook(view, "open", %{})
    render_async(view, 2_000)

    view |> form("#shell-search-form", %{"q" => "ketlebell"}) |> render_change()
    html = render_async(view, 2_000)

    assert html =~ ~s(href="/posts/#{question.id}")
    assert html =~ ~s(href="/#{site.origin}")

    view |> form("#shell-search-form", %{"q" => "empty_baskt"}) |> render_change()
    html = render_async(view, 2_000)

    assert html =~ ~s(href="/#{site.origin}/tools/empty_basket")
    assert html =~ "Tools"
  end

  test "one accented letter searches the questions and never says search is unavailable", %{
    conn: conn
  } do
    {:ok, view, _html} =
      live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor()})

    render_hook(view, "open", %{})
    render_async(view, 2_000)

    view |> form("#shell-search-form", %{"q" => "é"}) |> render_change()
    html = render_async(view, 2_000)

    refute html =~ "Search unavailable"
    refute html =~ "Search is unavailable"
  end

  test "past the address's searches for the minute, the window says to wait and shows no results",
       %{conn: conn} do
    site = Forum.register_site!("kettlebell.example")
    visitor = visitor()

    {:ok, view, _html} =
      live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor})

    view |> form("#shell-search-form", %{"q" => "kettlebell"}) |> render_change()
    assert render_async(view, 2_000) =~ ~s(href="/#{site.origin}")

    for _ <- 1..300, do: Patchbay.Limits.spend(:search_address, visitor)

    view |> form("#shell-search-form", %{"q" => "kettlebells"}) |> render_change()
    html = render_async(view, 2_000)
    assert has_element?(view, "#shell-search-limited")
    refute html =~ ~s(href="/#{site.origin}")
    refute has_element?(view, "[data-search-result]")
    refute html =~ "No results for"

    # Once the minute is over, the same words search again.
    PatchbayWeb.ReadLimit.set({:search_address, visitor}, 60_000, 0)
    view |> form("#shell-search-form", %{"q" => "kettlebell"}) |> render_change()
    html = render_async(view, 2_000)
    refute has_element?(view, "#shell-search-limited")
    assert html =~ ~s(href="/#{site.origin}")

    # Another address searches as before.
    {:ok, other, _html} =
      live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor()})

    other |> form("#shell-search-form", %{"q" => "nothing matches this"}) |> render_change()
    assert render_async(other, 2_000) =~ "No results for"
  end

  defp visitor, do: "visitor-" <> Ash.UUID.generate()
end
