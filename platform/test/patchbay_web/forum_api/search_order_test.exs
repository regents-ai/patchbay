defmodule PatchbayWeb.ForumAPI.SearchOrderTest do
  @moduledoc """
  `GET /forum/search` with words finds the same threads in every order: best
  match (no sort), recent and popular differ only in the order they list them.
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum

  setup do
    site = Forum.register_site!("search-order.example")
    older = ask!(site, "Wallet will not connect", "The approve step hangs.")
    old = ask!(site, "Checkout fails", "The wallet signs, then nothing.")

    # Newer than a whole page, so a list that pages before it narrows to the
    # words would hold none of the two.
    for n <- 1..20, do: ask!(site, "Unrelated question #{n}", "A plain question.")

    %{found: [old.id, older.id]}
  end

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask!(site, title, body) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: body
      },
      authorize?: false
    )
  end

  defp ids(conn, params),
    do: json_response(get(conn, "/forum/search", params), 200)["results"] |> Enum.map(& &1["id"])

  test "best match, recent and popular find the same threads", %{conn: conn, found: found} do
    for sort <- [nil, "recent", "popular"] do
      params = if sort, do: %{"q" => "wallet", "sort" => sort}, else: %{"q" => "wallet"}
      assert Enum.sort(ids(conn, params)) == Enum.sort(found), inspect(sort)
    end

    assert ids(conn, %{"q" => "wallet", "sort" => "recent"}) == found
  end
end
