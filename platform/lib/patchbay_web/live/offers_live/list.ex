defmodule PatchbayWeb.OffersLive.List do
  @moduledoc """
  The public directory of Offer markets: Global first, on its own, then
  every site on the board, searchable by name or address.

  Each of a market's three slots shows what is showing there, for how much,
  by whom and until when; the least that replaces it and what its owner
  would get back if it were replaced now; the next period's leader and the
  least that outbids it; or, when nothing is showing, the price it opens
  at. A site whose market has never been opened shows three empty slots at
  the global minimum.

  The figures cover the 72 hours before the moment the page was read,
  which the page states, and when counting began, if that was later.
  `PatchbayWeb.OffersLive.Markets` reads the markets and draws the slots.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, moment: 1, site_name: 1, site_path: 1]

  import PatchbayWeb.OffersLive.Markets, only: [global_tip: 1, offer_slot: 1, responses: 1]

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Returns
  alias PatchbayWeb.OffersLive.Markets

  @page 20

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Agent Offers markets")}

  # Every new search reads the whole page again as of one moment, so the
  # times, prices and figures on it all agree; "Show more" adds sites as of
  # that same moment.
  @impl true
  def handle_params(params, _uri, socket) do
    as_of = DateTime.utc_now()
    window = Returns.window(as_of)

    {:noreply,
     socket
     |> assign(
       text: params |> Map.get("q", "") |> String.trim(),
       as_of: as_of,
       window: window,
       counting_since: Returns.counting_since(),
       global: Markets.global(window),
       opportunities: Returns.global_opportunities(window),
       cursor: nil,
       more?: false,
       found: 0
     )
     |> stream(:sites, [], reset: true)
     |> read_sites()}
  end

  @impl true
  def handle_event("search", %{"q" => text}, socket) do
    query = if String.trim(text) == "", do: [], else: [q: text]
    {:noreply, push_patch(socket, to: ~p"/offers/list?#{query}")}
  end

  def handle_event("more", _params, socket), do: {:noreply, read_sites(socket)}

  defp read_sites(socket) do
    %{text: text, cursor: cursor, window: window} = socket.assigns
    page = [limit: @page] ++ if(cursor, do: [after: cursor], else: [])

    {:ok, %{results: sites, more?: more?}} =
      Forum.list_directory(query: sites_query(text, window), page: page)

    markets = Markets.site_markets(Enum.map(sites, & &1.id), window)

    entries =
      Enum.map(sites, fn site -> %{id: site.id, site: site, market: markets[site.id]} end)

    socket
    |> stream(:sites, entries)
    |> assign(more?: more?, found: socket.assigns.found + length(sites))
    |> assign_cursor(List.last(sites))
  end

  defp assign_cursor(socket, nil), do: socket
  defp assign_cursor(socket, last), do: assign(socket, cursor: last.__metadata__.keyset)

  defp sites_query("", window), do: Returns.count_site_responses(Site, window)

  defp sites_query(text, window) do
    Site
    |> Ash.Query.filter(
      contains(string_downcase(origin), string_downcase(^text)) or
        contains(string_downcase(display_name), string_downcase(^text))
    )
    |> Returns.count_site_responses(window)
  end

  @doc "What the figures on the page cover, stated exactly."
  def coverage({_since, as_of}, nil),
    do: "As of #{moment(as_of)}. Nothing has been counted yet."

  def coverage({since, as_of}, counting_since) do
    if DateTime.after?(counting_since, since),
      do: "Figures cover #{moment(counting_since)} to #{moment(as_of)}, since counting began.",
      else: "Figures cover the 72 hours before #{moment(as_of)}."
  end
end
