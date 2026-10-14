defmodule PatchbayWeb.SearchLiveTest do
  @moduledoc """
  The search window every page shares: what a reader types finds both the
  questions and the sites that match.
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
    render_async(view)

    view |> element("#search-dialog-q") |> render_change(%{"q" => "kettlebell"})
    html = render_async(view)

    assert html =~ ~s(href="/posts/#{question.id}")
    assert html =~ ~s(href="/#{site.origin}")
    assert html =~ ~s(href="/?q=kettlebell")
  end
end
