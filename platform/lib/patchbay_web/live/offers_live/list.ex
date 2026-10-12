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
         editor_mode: "create",
         page_title: "Agent Offers",
         max_code_points: Patchbay.Offers.CreativeText.max_code_points(),
         hours: div(Patchbay.Offers.Terms.duration_us(), 3_600_000_000),
         minimum: credits(Offers.default_minimum_minor())
       )}

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
    {:noreply, push_patch(socket, to: ~p"/offers?#{query}")}
  end

  def handle_event("more", _params, socket), do: {:noreply, read_sites(socket)}

  def handle_event("open_editor", %{"mode" => mode}, socket) when mode in ["create", "edit"],
    do: {:noreply, assign(socket, editor_open?: true, editor_mode: mode)}

  def handle_event("close_editor", _params, socket),
    do: {:noreply, assign(socket, editor_open?: false)}

  # Events stay on the hosting LiveView, so its session check runs before
  # the shared editor reads or saves anything for the current account.
  def handle_event(event, params, socket)
      when event in ~w(check save reword check_reword cancel_reword save_reword),
      do: Create.handle_event(event, params, socket)

  @impl true
  def handle_info(:offer_reviews_changed, socket),
    do: Create.handle_info(:offer_reviews_changed, socket)

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

  defp find_slot(market, number), do: market && Enum.find(market.slots, &(&1.number == number))

  defp slot_state(%{active_placement: placement}, now) when not is_nil(placement),
    do: if(showing?(placement, now), do: "Live", else: "Open")

  defp slot_state(_slot, _now), do: "Open"

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
