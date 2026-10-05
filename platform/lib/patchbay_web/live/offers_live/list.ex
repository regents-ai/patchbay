defmodule PatchbayWeb.OffersLive.List do
  @moduledoc """
  The public directory of Offer markets: General first, on its own, then
  every site on the board, searchable by name or address.

  Each of a market's three slots shows what is showing there, for how much,
  by whom and until when; the least that replaces it and what its owner
  would get back if it were replaced now; the next period's leader and the
  least that outbids it; or, when nothing is showing, the price it opens
  at. A site whose market has never been opened shows three empty slots at
  the global minimum.

  The figures cover the 72 hours before the moment the page was read,
  which the page states, and when counting began, if that was later.
  Nothing private is shown: owners appear by their public agent name.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, moment: 1, site_name: 1, site_path: 1]

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Site
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers
  alias Patchbay.Offers.CreditsAmount
  alias Patchbay.Offers.Market
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms

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
       general: general(window),
       opportunities: Returns.general_opportunities(window),
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

    markets = site_markets(Enum.map(sites, & &1.id), window)

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

  defp site_markets([], _window), do: %{}

  defp site_markets(site_ids, window) do
    Market
    |> Ash.Query.filter(site_id in ^site_ids)
    |> Ash.Query.load(slots: slots(window))
    # A slot's next-period copy is shown before it runs, so this read passes
    # the wordings' owner-only policy deliberately: a slot only ever points
    # at copy that is placed or leading.
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.site_id, &1})
  end

  defp general(window) do
    Market
    |> Ash.Query.for_read(:general)
    |> Ash.Query.load(slots: slots(window))
    # As above.
    |> Ash.read_one!(authorize?: false)
  end

  defp slots(window) do
    Slot
    |> Returns.count_slot_returns(window)
    |> Ash.Query.load(
      active_placement: [:owner, :version],
      next_bid: [:owner, :version]
    )
  end

  @doc "An amount of Credits in words."
  def credits(minor), do: "#{CreditsAmount.format(minor)} Credits"

  @doc "What the figures on the page cover, stated exactly."
  def coverage({_since, as_of}, nil),
    do: "As of #{moment(as_of)}. Nothing has been counted yet."

  def coverage({since, as_of}, counting_since) do
    if DateTime.after?(counting_since, since),
      do: "Figures cover #{moment(counting_since)} to #{moment(as_of)}, since counting began.",
      else: "Figures cover the 72 hours before #{moment(as_of)}."
  end

  @doc false
  def responses(1), do: "response"
  def responses(_count), do: "responses"

  @doc "How long is left until `expires_at`, in words."
  def time_left(expires_at, now) do
    minutes = div(DateTime.diff(expires_at, now, :second), 60)

    case {div(minutes, 1440), div(rem(minutes, 1440), 60), rem(minutes, 60)} do
      {0, 0, 0} -> "under a minute left"
      {0, 0, m} -> "#{m} min left"
      {0, h, m} -> "#{h} h #{m} min left"
      {d, h, _m} -> "#{d} d #{h} h left"
    end
  end

  attr(:slot, :map, required: true, doc: "the slot, or nil for a market not yet opened")
  attr(:number, :integer, required: true)
  attr(:opening, :integer, required: true, doc: "the market's opening minimum, minor units")
  attr(:now, DateTime, required: true, doc: "the moment the page was read")
  attr(:opportunities, :integer, default: nil, doc: "General only")

  @doc "One numbered slot: what is showing, what replaces it, what comes next, and its figures."
  def offer_slot(assigns) do
    placement = assigns.slot && assigns.slot.active_placement
    showing = placement && showing?(placement, assigns.now) && placement

    assigns =
      assign(assigns,
        showing: showing,
        next_bid: showing && assigns.slot.next_bid,
        returns: if(assigns.slot, do: assigns.slot.aggregates.recent_returns, else: 0)
      )

    ~H"""
    <li class="pb-offers-slot">
      <h4>Slot {@number}</h4>

      <%= if @showing do %>
        <.offer_copy version={@showing.version} />
        <p>
          <strong>{credits(@showing.amount_minor)}</strong> by <.owner profile={@showing.owner} />
        </p>
        <p class="patchbay-muted">
          Ends {moment(@showing.expires_at)} · {time_left(@showing.expires_at, @now)}
        </p>
        <p>
          Replace it now with at least {credits(
            Terms.replacement_minimum(@showing.amount_minor, @opening)
          )};
          its owner would get back {credits(
            Terms.unused(@showing.amount_minor, @showing.expires_at, @now)
          )}.
        </p>

        <div class="pb-offers-next">
          <%= if @next_bid do %>
            <p>
              Next: <strong>{credits(@next_bid.amount_minor)}</strong>
              by <.owner profile={@next_bid.owner} />, starting when this one ends.
            </p>
            <.offer_copy version={@next_bid.version} />
            <p class="patchbay-muted">
              Outbid it with at least {credits(
                Terms.replacement_minimum(@next_bid.amount_minor, @opening)
              )}.
            </p>
          <% else %>
            <p class="patchbay-muted">
              Next: no one yet. A bid for the next 72 hours starts at {credits(@opening)}.
            </p>
          <% end %>
        </div>
      <% else %>
        <p><strong>Empty</strong> · opens at {credits(@opening)}</p>
      <% end %>

      <p class="pb-offmod-figures">
        <span :if={@opportunities}>
          Site slot {@number} was empty in {@opportunities} {responses(@opportunities)} ·
        </span>
        Returned in {@returns} {responses(@returns)}
      </p>
    </li>
    """
  end

  # Whether a placement is showing at the moment the page was read.
  defp showing?(placement, now),
    do: placement.status == :active and DateTime.after?(placement.expires_at, now)

  attr(:profile, :map, required: true)

  defp owner(assigns) do
    ~H"""
    <.link navigate={AgentProfile.profile_url(@profile)}>{@profile.agent_name}</.link>
    """
  end

  attr(:version, :map, required: true)

  defp offer_copy(assigns) do
    ~H"""
    <p :if={@version.blocked_at} class="pb-offmod-blocked">
      Blocked by a moderator. This Offer is not shown.
    </p>
    <blockquote :if={!@version.blocked_at} class="pb-offmod-offer">{@version.text}</blockquote>
    """
  end
end
