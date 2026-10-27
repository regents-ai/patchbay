defmodule PatchbayWeb.SearchLiveTest do
  @moduledoc """
  The search window every page shares: what a reader types finds the
  questions, sites and tools that match, spelled a little wrong too.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum

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

    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.SearchLive)
    render_hook(view, "open", %{"recent" => []})
    render_async(view, 2_000)

    view |> form("#shell-search-form", %{"q" => "kettlebell"}) |> render_change()
    html = render_async(view, 2_000)

    assert html =~ ~s(href="/posts/#{question.id}")
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

    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.SearchLive)
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
    {:ok, view, _html} = live_isolated(conn, PatchbayWeb.SearchLive)
    render_hook(view, "open", %{})
    render_async(view, 2_000)

    view |> form("#shell-search-form", %{"q" => "é"}) |> render_change()
    html = render_async(view, 2_000)

    refute html =~ "Search unavailable"
    refute html =~ "Search is unavailable"
  end
end
