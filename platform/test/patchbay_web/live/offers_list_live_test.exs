defmodule PatchbayWeb.OffersLive.ListTest do
  # The website list on /offers searches as a visitor types. Every search the
  # connected page reads, including one it joins with, spends the address's
  # 300 searches a minute; past them the page says to wait and reads nothing.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias PatchbayWeb.ClientAddress

  setup %{conn: conn} do
    origin = "list-#{System.unique_integer([:positive])}.example"
    {:ok, _site} = Forum.register_site(origin, authorize?: false)
    n = System.unique_integer([:positive])
    conn = %{conn | remote_ip: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}}
    %{conn: conn, origin: origin}
  end

  defp spend_all(conn) do
    visitor = ClientAddress.visitor_key(conn)
    for _ <- 1..300, do: Patchbay.Limits.spend(:search_address, visitor)
  end

  test "a search finds the website until the address has searched too often",
       %{conn: conn, origin: origin} do
    {:ok, view, _html} = live(conn, "/offers")

    view |> form("#pb-offers-search", q: origin) |> render_change()
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
    refute has_element?(view, "#pb-offers-limited")

    spend_all(conn)

    view |> form("#pb-offers-search", q: String.slice(origin, 0, 8)) |> render_change()
    assert render(view) =~ "You&#39;re searching quickly. Wait a moment and search again."
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")
    refute render(view) =~ "No website matches"

    # Asking for more of the refused search reads nothing either.
    render_click(view, "more", %{})
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")

    # The list of every website is not a search.
    view |> form("#pb-offers-search", q: "") |> render_change()
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
  end

  test "joining the page with a search in its address is a search too",
       %{conn: conn, origin: origin} do
    spend_all(conn)

    {:ok, view, _html} = live(conn, "/offers?q=#{origin}")
    assert has_element?(view, "#pb-offers-limited")
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")
  end
end
