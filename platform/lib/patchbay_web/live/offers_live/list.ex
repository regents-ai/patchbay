defmodule PatchbayWeb.OffersLive.List do
  @moduledoc "The public website gallery, ranked by total posts."

  use PatchbayWeb, :live_view

  import PatchbayWeb.OffersLive.Navigation, only: [offers_header: 1]

  import PatchbayWeb.Forum.BoardHTML,
    only: [
      moment: 1,
      site_name: 1,
      site_path: 1,
      site_domain: 1,
      site_logo_url: 1,
      monogram: 1
    ]

  import PatchbayWeb.OffersLive.Markets, only: [credits: 1, showing?: 2]

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Returns
  alias PatchbayWeb.OffersLive.BidDesk
  alias PatchbayWeb.OffersLive.Markets

  @page 12

  @impl true
  def mount(_params, session, socket),
    do:
      {:ok,
       socket
       |> assign(PatchbayWeb.PublicDocuments.page("/offers"))
       |> assign(
         max_code_points: Patchbay.Offers.CreativeText.max_code_points(),
         hours: div(Patchbay.Offers.Terms.duration_us(), 3_600_000_000),
         visitor: Map.fetch!(session, "visitor")
       )}

  # The address holds the search, so a reload or a reconnect shows the same page.
  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, search(socket, params |> Map.get("q", "") |> String.trim())}

  @impl true
  def handle_event("search", %{"q" => text}, socket) do
    query = if String.trim(text) == "", do: [], else: [q: text]
    {:noreply, push_patch(socket, to: ~p"/offers?#{query}")}
  end

  def handle_event("more", _params, %{assigns: %{more?: true}} = socket),
    do:
      {:noreply, if(admitted?(socket, socket.assigns.text), do: read_sites(socket), else: socket)}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  # The same search keeps the sites already shown, unless it was refused. Every
  # new search reads the whole page again as of one moment, so the times,
  # prices and figures on it all agree; "Show more" adds sites as of that same
  # moment. A refused search reads nothing: the page keeps the figures it has
  # and lists no websites, and searching again once the allowance is back goes
  # through.
  defp search(%{assigns: %{text: text, limited?: false}} = socket, text), do: socket

  defp search(socket, text) do
    if admitted?(socket, text),
      do: socket |> read_moment() |> start_search(text, false) |> read_sites(),
      else: socket |> first_moment() |> start_search(text, true)
  end

  defp start_search(socket, text, limited?),
    do:
      socket
      |> assign(text: text, cursor: nil, more?: false, found: 0, limited?: limited?)
      |> stream(:sites, [], reset: true)

  defp read_moment(socket) do
    as_of = DateTime.utc_now()
    window = Returns.window(as_of)

    assign(socket,
      as_of: as_of,
      window: window,
      counting_since: Returns.counting_since(),
      global: Markets.global(window)
    )
  end

  # Joining the page reads its figures once, as the page without a search does,
  # even when the search it joins with is refused.
  defp first_moment(%{assigns: %{global: _global}} = socket), do: socket
  defp first_moment(socket), do: read_moment(socket)

  # Each page of a search the connected page reads spends the visitor's search
  # allowance (`Patchbay.Limits`), as in ash-template, so joining the page again
  # with a new address is a search too. The first drawing is a request the read
  # share already counts, and the list of every website is not a search.
  defp admitted?(_socket, ""), do: true

  defp admitted?(socket, _text),
    do:
      not connected?(socket) or
        Patchbay.Limits.spend(:search_address, socket.assigns.visitor) == :ok

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

  defp sites_query("", window), do: ranked_sites(window)

  defp sites_query(text, window) do
    ranked_sites(window)
    |> Ash.Query.filter(
      contains(string_downcase(origin), string_downcase(^text)) or
        contains(string_downcase(display_name), string_downcase(^text))
    )
  end

  defp ranked_sites(window) do
    query =
      Site
      |> Ash.Query.for_read(:directory)
      |> Returns.count_site_responses(window)
      |> Ash.Query.load(:report_count)
      |> Ash.Query.unset(:sort)

    Ash.Query.sort(query, [
      {:report_count, :desc},
      {:display_name, :asc},
      {:origin, :asc},
      {:id, :asc}
    ])
  end

  attr(:label, :string, required: true)
  attr(:market, :map, required: true)
  attr(:site_id, :string, default: nil, doc: "none for Global's slots")
  attr(:as_of, DateTime, required: true)
  attr(:id, :string, required: true)

  # A rail of the market's slots, read like a game menu. Slots with an Offer
  # showing and the one slot for sale are full tiles; the open slots after it
  # wait as narrow locked parts until it is taken (`Patchbay.Offers.SlotOrder`).
  # The rail's height is fixed, so no state moves what sits below it.
  defp slots(assigns) do
    %{market: market, as_of: as_of} = assigns

    assigns =
      assign(assigns,
        tiles:
          for number <- 1..3 do
            slot = find_slot(market, number)

            %{
              number: number,
              turn: BidDesk.turn(market, number, as_of),
              price: credits(slot_price(slot, market, as_of))
            }
          end
      )

    ~H"""
    <nav class="pb-slots" aria-label={@label} phx-hook="OfferSlots" id={@id}>
      <%= for tile <- @tiles do %>
        <%= case tile.turn do %>
          <% :showing -> %>
            <.link
              navigate={bid_path(@site_id, tile.number)}
              class="pb-slot pb-slot--live"
              data-slot
            >
              <span class="pb-slot-top"><span class="pb-slot-number" aria-hidden="true">0{tile.number}</span><span class="visually-hidden">Slot {tile.number}</span><span
                class="pb-slot-go"
                aria-hidden="true"
              >▸</span></span>
              <span class="pb-slot-tag">Live</span>
              <span class="pb-slot-price">From {tile.price}</span>
            </.link>
          <% :for_sale -> %>
            <.link
              navigate={bid_path(@site_id, tile.number)}
              class="pb-slot pb-slot--open"
              data-slot
              data-open
            >
              <span class="pb-slot-scan" aria-hidden="true" data-scan></span>
              <span class="pb-slot-top"><span class="pb-slot-number" aria-hidden="true">0{tile.number}</span><span class="visually-hidden">Slot {tile.number}</span><span
                class="pb-slot-go"
                aria-hidden="true"
              ><span class="pb-slot-go-word">Bid </span>▸</span></span>
              <span class="pb-slot-tag">Available</span>
              <span class="pb-slot-price">From {tile.price}</span>
            </.link>
          <% {:waiting, for_sale} -> %>
            <span
              class="pb-slot pb-slot--locked"
              title={"Opens when slot #{for_sale} is taken"}
              data-slot
            >
              <span class="pb-slot-number" aria-hidden="true">0{tile.number}</span>
              <span class="pb-slot-bars" aria-hidden="true"><i></i><i></i><i></i></span>
              <span class="visually-hidden">Slot {tile.number}: opens when slot {for_sale} is taken</span>
            </span>
        <% end %>
      <% end %>
    </nav>
    """
  end

  defp bid_path(nil, number), do: ~p"/offers/bid?#{[slot: number]}"
  defp bid_path(site_id, number), do: ~p"/offers/bid?#{[site: site_id, slot: number]}"

  defp find_slot(market, number), do: market && Enum.find(market.slots, &(&1.number == number))

  defp slot_price(%{active_placement: placement}, market, now) when not is_nil(placement) do
    if showing?(placement, now),
      do:
        Patchbay.Offers.Terms.replacement_minimum(
          placement.amount_minor,
          Offers.opening_minimum_minor(market)
        ),
      else: Offers.opening_minimum_minor(market)
  end

  defp slot_price(_slot, market, _now), do: Offers.opening_minimum_minor(market)

  @doc "What the figures on the page cover, stated exactly."
  def coverage({_since, as_of}, nil),
    do: "As of #{moment(as_of)}. Nothing has been counted yet."

  def coverage({since, as_of}, counting_since) do
    if DateTime.after?(counting_since, since),
      do: "Figures cover #{moment(counting_since)} to #{moment(as_of)}, since counting began.",
      else: "Figures cover the 72 hours before #{moment(as_of)}."
  end
end
