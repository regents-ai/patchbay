defmodule PatchbayWeb.OffersLive.ListTest do
  # The website list on /offers searches as a visitor types. Every search the
  # connected page reads, including one it joins with, spends the address's
  # 300 searches a minute; past them the page says to wait and reads nothing,
  # and the same words searched again once the minute is over go through.
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

  # The minute is over: the address's count starts again.
  defp new_minute(conn),
    do: PatchbayWeb.ReadLimit.set({:search_address, ClientAddress.visitor_key(conn)}, 60_000, 0)

  # The tables the page reads from now on, sent to this test as they are read.
  defp watch_reads do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, %{source: source}, _config -> send(test, {:read, source}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a search finds the website until the address has searched too often",
       %{conn: conn, origin: origin} do
    {:ok, view, _html} = live(conn, "/offers")

    view |> form("#pb-offers-search", q: origin) |> render_change()
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
    refute has_element?(view, "#pb-offers-limited")

    spend_all(conn)
    watch_reads()

    view |> form("#pb-offers-search", q: String.slice(origin, 0, 8)) |> render_change()
    assert render(view) =~ "You&#39;re searching quickly. Wait a moment and search again."
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")
    refute render(view) =~ "No website matches"

    # A refused search reads neither the websites nor the Global slots.
    refute_received {:read, "forum_sites"}
    refute_received {:read, "offer_markets"}

    # Asking for more of the refused search reads nothing either.
    render_click(view, "more", %{})
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")

    # The list of every website is not a search.
    view |> form("#pb-offers-search", q: "") |> render_change()
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
  end

  test "a refused search goes through when it is searched again in a new minute",
       %{conn: conn, origin: origin} do
    {:ok, view, _html} = live(conn, "/offers")
    spend_all(conn)

    view |> form("#pb-offers-search", q: origin) |> render_change()
    assert has_element?(view, "#pb-offers-limited")
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")

    new_minute(conn)

    view |> form("#pb-offers-search", q: origin) |> render_change()
    refute has_element?(view, "#pb-offers-limited")
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
  end

  test "joining the page with a search in its address is a search too",
       %{conn: conn, origin: origin} do
    spend_all(conn)

    {:ok, view, _html} = live(conn, "/offers?q=#{origin}")
    assert has_element?(view, "#pb-offers-limited")
    refute has_element?(view, "#pb-offers-markets .pb-offers-market")

    # Reloading the same address once the minute is over shows the website.
    new_minute(conn)
    {:ok, view, _html} = live(conn, "/offers?q=#{origin}")
    refute has_element?(view, "#pb-offers-limited")
    assert has_element?(view, "#pb-offers-markets .pb-offers-market", origin)
  end
end
