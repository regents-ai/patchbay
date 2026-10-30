defmodule Patchbay.Forum.FeedCountTest do
  @moduledoc """
  A question list's count is read once and kept a minute for every visitor
  reading that list in either order; another list, or the Following list with
  other follows, is counted on its own.
  """

  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias PatchbayWeb.Forum.Discussions

  test "a list's count is kept, and another list is counted on its own" do
    site = Forum.register_site!("counted.example")
    ask(site, "The first question")
    {:ok, newest} = Discussions.filters(%{})
    {:ok, popular} = Discussions.filters(%{"sort" => "popular"})
    {:ok, on_site} = Discussions.filters(%{"site" => site.origin})

    assert Discussions.count(newest) == {:ok, 1}

    ask(site, "The second question")

    assert Discussions.count(newest) == {:ok, 1}
    assert Discussions.count(popular) == {:ok, 1}
    assert Discussions.count(on_site) == {:ok, 2}
  end

  test "the Following list is kept under the follows it was counted with" do
    followed = Forum.register_site!("followed.example")
    other = Forum.register_site!("other.example")
    ask(followed, "On the followed site")
    ask(other, "On the other site")
    {:ok, following} = Discussions.filters(%{"scope" => "following"})

    assert Discussions.count(following, [follow(followed)]) == {:ok, 1}
    assert Discussions.count(following, [follow(followed), follow(other)]) == {:ok, 2}
    assert Discussions.count(following, []) == {:ok, 0}
  end

  defp follow(site), do: %{scope_kind: :site, scope_id: site.id}

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask(site, title) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: "Asked on the board."
      },
      authorize?: false
    )
  end
end
