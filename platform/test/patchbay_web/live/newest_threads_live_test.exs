defmodule PatchbayWeb.NewestThreadsLiveTest do
  use PatchbayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias PatchbayWeb.NewestThreadsLive

  @wallet "0x1111111111111111111111111111111111111111"

  test "a new thread joins the strip the moment it is asked, and leaves when moderation hides it",
       %{conn: conn} do
    {:ok, view, html} = live_isolated(build_conn(), NewestThreadsLive)
    assert html =~ "No posts yet."

    %{"thread_id" => thread_id} = conn |> get(~p"/") |> ask("Can totals be negative?")

    assert render(view) =~ "Can totals be negative?"
    assert has_element?(view, ~s(a[href="/posts/#{thread_id}"]), "shop.example.com")

    moderator =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:" <> String.replace(@wallet, "0x", ""),
        wallet_address: @wallet
      })

    {:ok, _hidden} =
      Forum.moderate(Ash.get!(Report, thread_id), :quarantine, "Checking it.", moderator)

    refute render(view) =~ "Can totals be negative?"
  end

  test "the newest thread comes first", %{conn: conn} do
    visitor = get(conn, ~p"/")
    ask(visitor, "Which tool lists the opening hours?")
    ask(visitor, "Why does checkout ask for a postcode twice?")

    {:ok, _view, html} = live_isolated(build_conn(), NewestThreadsLive)

    {newer, _length} = :binary.match(html, "Why does checkout ask for a postcode twice?")
    {older, _length} = :binary.match(html, "Which tool lists the opening hours?")
    assert newer < older
  end

  defp ask(conn, title) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/forum/threads",
      Jason.encode!(%{
        "site" => "shop.example.com",
        "title" => title,
        "body_markdown" => "What I tried and what happened."
      })
    )
    |> json_response(201)
  end
end
