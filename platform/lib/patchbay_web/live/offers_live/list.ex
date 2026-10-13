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
      site_screenshot_url: 1,
      monogram: 1
    ]

  import PatchbayWeb.OffersLive.Markets, only: [credits: 1, showing?: 2]

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Returns
  alias PatchbayWeb.OffersLive.Create
  alias PatchbayWeb.OffersLive.Markets

  @page 12

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> Create.initialize_editor()
       |> assign(
         editor_open?: false,
         page_title: "Agent Offers",
         max_code_points: Patchbay.Offers.CreativeText.max_code_points(),
         hours: div(Patchbay.Offers.Terms.duration_us(), 3_600_000_000),
         minimum: credits(Offers.default_minimum_minor())
       )}

  # The address holds the search and the editor: whether it is open and the
  # saved Offer being reworded, so a reload or a reconnect shows the same page.
  @impl true
  def handle_params(params, uri, socket) do
    editor_open? = params["editor"] == "create"

    {:noreply,
     socket
     |> assign(editor_open?: editor_open?)
     |> Create.editor_params(if(editor_open?, do: params, else: %{}), uri)
     |> search(params |> Map.get("q", "") |> String.trim())}
  end

  @impl true
  def handle_event("search", %{"q" => text}, socket) do
    q = if String.trim(text) == "", do: nil, else: text
    {:noreply, Create.patch_editor(socket, %{"q" => q})}
  end

  def handle_event("more", _params, socket), do: {:noreply, read_sites(socket)}

  def handle_event("open_editor", _params, socket),
    do: {:noreply, Create.patch_editor(socket, %{"editor" => "create"})}

  def handle_event("close_editor", _params, socket),
    do:
      {:noreply,
       Create.patch_editor(socket, %{"editor" => nil, "reword" => nil, "delete" => nil})}

  # Events stay on the hosting LiveView, so its session check runs before
  # the shared editor reads or saves anything for the current account.
  def handle_event(event, params, socket)
      when event in ~w(check save reword check_reword cancel_reword save_reword ask_delete cancel_delete delete),
      do: Create.handle_event(event, params, socket)

  @impl true
  def handle_info(:offer_reviews_changed, socket),
    do: Create.handle_info(:offer_reviews_changed, socket)

  # The same search keeps the sites already shown. Every new search reads the
  # whole page again as of one moment, so the times, prices and figures on it
  # all agree; "Show more" adds sites as of that same moment.
  defp search(%{assigns: %{text: text}} = socket, text), do: socket

  defp search(socket, text) do
    as_of = DateTime.utc_now()
    window = Returns.window(as_of)

    socket
    |> assign(
      text: text,
      as_of: as_of,
      window: window,
      counting_since: Returns.counting_since(),
      global: Markets.global(window),
      cursor: nil,
      more?: false,
      found: 0
    )
    |> stream(:sites, [], reset: true)
    |> read_sites()
  end

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

  # One slot is for sale at a time: the lowest-numbered open one. The open
  # slots after it wait, greyed, until it is taken. A live slot can always be
  # outbid. Each tile keeps three lines, so the card's height never changes.
  defp slots(assigns) do
    %{market: market, as_of: as_of} = assigns
    live = Enum.filter(1..3, &live?(find_slot(market, &1), as_of))
    assigns = assign(assigns, live: live, for_sale: Enum.find(1..3, &(&1 not in live)))

    ~H"""
    <nav class="pb-offers-gallery-slots" aria-label={@label}>
      <%= for number <- 1..3 do %>
        <.link
          :if={number in @live}
          navigate={bid_path(@site_id, number)}
          class="pb-offers-slot-live"
        ><strong>Slot {number}
        <span aria-hidden="true">↗</span></strong><span>Live</span><small>From {credits(
          slot_price(find_slot(@market, number), @market, @as_of)
        )}</small></.link>
        <.link
          :if={number == @for_sale}
          navigate={bid_path(@site_id, number)}
          class="pb-offers-slot-open"
        ><strong>Slot {number}
        <span aria-hidden="true">↗</span></strong><span>Available</span><small>From {credits(
          slot_price(find_slot(@market, number), @market, @as_of)
        )}</small></.link>
        <span
          :if={number not in @live and number != @for_sale}
          class="pb-offers-slot-waiting"
        ><strong>Slot {number}</strong><span>Waiting</span><small>Opens when slot {@for_sale} is taken</small></span>
      <% end %>
    </nav>
    """
  end

  defp bid_path(nil, number), do: ~p"/offers/bid?#{[slot: number]}"
  defp bid_path(site_id, number), do: ~p"/offers/bid?#{[site: site_id, slot: number]}"

  defp find_slot(market, number), do: market && Enum.find(market.slots, &(&1.number == number))

  defp live?(%{active_placement: placement}, now) when not is_nil(placement),
    do: showing?(placement, now)

  defp live?(_slot, _now), do: false

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
