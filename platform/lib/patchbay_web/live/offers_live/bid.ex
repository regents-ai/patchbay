defmodule PatchbayWeb.OffersLive.Bid do
  @moduledoc """
  Bidding on one numbered slot: Global's, or a site's (`?site=`), with
  `?slot=` 1 to 3.

  The page shows the slot as it stands, then, for a signed-in advertiser,
  their Credits, the form and their own bids on this slot. The form names
  the exact slot, lane, approved wording and amount; the amount starts at
  the lane's minimum. Every bid carries the slot's generation (and, for the
  next period, its leader's revision) as the page read them, so a slot that
  moved on refuses the bid and the page reads it again; the page never
  raises an amount or changes a lane on its own. Until a detail changes or
  the slot moves on, every press sends the same request key, so a repeat
  answers with the first bid and never holds twice.

  A site's market is opened when it is first needed: a bid, or asking
  whether a wording fits the site. Open pages hear `Patchbay.Offers.Slot`'s
  topic and read the slot, the bids and the balance again, and read the
  balance again whenever the advertiser's Credits move.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.OffersLive.Navigation, only: [offers_header: 1]

  import PatchbayWeb.Forum.BoardHTML,
    only: [moment: 1, site_name: 1, site_path: 1]

  import PatchbayWeb.OffersLive.Markets,
    only: [credits: 1, offer_copy: 1, hours_until: 2, time_left: 2]

  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.OffersLive.BidDesk
  alias PatchbayWeb.OffersLive.Create

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Slot.topic())
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Review.topic())
      follow_credits(socket.assigns.current_profile)
    end

    {:ok,
     assign(socket,
       page_title: "Bid on an Offer slot",
       problem: nil,
       outbid?: false,
       short?: false,
       screening_paused?: Offers.screening_paused?()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    number = number(params["slot"])
    site = site(params["site"])

    {:noreply,
     socket
     |> assign(
       number: number,
       site: site,
       lane: :immediate,
       version_id: nil,
       amount: nil,
       bids: [],
       outbid?: false
     )
     |> read()
     |> prefill()}
  end

  @impl true
  def handle_info(:offer_markets_changed, socket), do: {:noreply, read(socket)}

  def handle_info(:offer_reviews_changed, socket), do: {:noreply, read(socket)}

  def handle_info(:credits_changed, socket), do: {:noreply, read(socket)}

  @impl true
  def handle_event("dismiss_outbid", _params, socket),
    do: {:noreply, assign(socket, outbid?: false)}

  def handle_event("change", %{"bid" => params}, socket) do
    lane = lane(params["lane"])
    socket = assign(socket, version_id: params["version_id"], problem: nil, short?: false)

    {:noreply,
     if(lane == socket.assigns.lane,
       do: socket |> assign(amount: params["amount"]) |> new_key(),
       else: socket |> assign(lane: lane) |> assign_minimum() |> prefill()
     )}
  end

  # Bidding and asking act for a signed-in advertiser, so a press from
  # nobody opens nothing.
  def handle_event(event, _params, %{assigns: %{current_profile: nil}} = socket)
      when event in ["bid", "ask_fit"],
      do: {:noreply, assign(socket, problem: "Sign in at the top of the page to bid.")}

  def handle_event("bid", %{"bid" => params}, socket) do
    socket =
      assign(socket,
        lane: lane(params["lane"]),
        version_id: params["version_id"],
        amount: params["amount"]
      )

    case place(socket) do
      {:ok, bid} ->
        # Settlement can finish before the page's next read. Keep the accepted
        # held bid in this view's baseline so its result is still noticed.
        socket =
          if bid.status == :held,
            do: assign(socket, bids: [bid | socket.assigns.bids]),
            else: socket

        {:noreply, socket |> assign(problem: nil, short?: false) |> read()}

      {:error, error} ->
        {kind, words} = BidDesk.refusal(error)

        {:noreply,
         socket |> assign(problem: words, short?: kind == :not_enough_credits) |> read()}
    end
  end

  def handle_event("ask_fit", %{"version_id" => id}, socket) do
    case BidDesk.ask_fit(socket.assigns.current_profile, socket.assigns.site, id) do
      {:ok, _review} ->
        {:noreply, socket |> assign(problem: nil, short?: false) |> read()}

      {:error, _error} ->
        {:noreply, assign(socket, problem: "That could not be asked. Try again.", short?: false)}
    end
  end

  # The balance shown is current whichever Regent site moved the Credits.
  defp follow_credits(nil), do: :ok

  defp follow_credits(profile),
    do:
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(profile.privy_user_id))

  defp place(socket) do
    %{site: site, number: number, slot: slot} = socket.assigns

    BidDesk.place(socket.assigns.current_profile, site, number, %{
      lane: socket.assigns.lane,
      amount: socket.assigns.amount,
      version_id: socket.assigns.version_id,
      # As the page read them; a slot not yet opened starts at nothing.
      generation: if(slot, do: slot.active_generation, else: 0),
      next_revision: if(slot, do: slot.next_revision, else: 0),
      key: socket.assigns.key
    })
  end

  defp read(socket) do
    %{site: site, number: number, current_profile: profile} = socket.assigns
    now = DateTime.utc_now()
    market = BidDesk.market(site, Returns.window(now))
    slot = BidDesk.slot(market, number)
    showing = BidDesk.showing(slot, now)
    mine = BidDesk.mine(profile, market, slot, now)
    previous = Map.new(socket.assigns[:bids] || [], &{&1.id, &1.status})

    # A committed returned/outbid record means its full hold was refunded in
    # the same transaction. Historical results and repeated reads stay quiet.
    outbid? =
      Enum.any?(mine.bids, fn bid ->
        bid.status == :returned and bid.return_reason == :outbid and
          Map.get(previous, bid.id) == :held
      end)

    socket
    |> renew_key_if_moved(socket.assigns[:slot], slot)
    |> assign(now: now, market: market, slot: slot, opening: Offers.opening_minimum_minor(market))
    |> assign(turn: BidDesk.turn(market, number, now))
    |> assign(duration_returns: Returns.placement_returns(showing, now))
    |> assign(showing: showing, terms: BidDesk.terms(showing))
    |> assign(mine)
    |> assign(outbid?: socket.assigns.outbid? or outbid?)
    |> assign_minimum()
    |> choose_wording()
  end

  # Approval can arrive while this page is open. Keep a still-eligible selection;
  # otherwise choose the first approved wording without changing the bid amount.
  defp choose_wording(socket) do
    %{wordings: wordings, version_id: selected} = socket.assigns

    if Enum.any?(wordings, &(&1.eligible? and &1.version.id == selected)) do
      socket
    else
      next = first_eligible(wordings)
      if next == selected, do: socket, else: socket |> assign(version_id: next) |> new_key()
    end
  end

  defp assign_minimum(socket), do: assign(socket, minimum: minimum(socket.assigns))

  # The amount starts at the lane's minimum, and a new amount is a new
  # request.
  defp prefill(socket) do
    socket
    |> assign(amount: CreditAmount.format(socket.assigns.minimum))
    |> assign(version_id: socket.assigns.version_id || first_eligible(socket.assigns.wordings))
    |> new_key()
  end

  defp new_key(socket), do: assign(socket, key: Ecto.UUID.generate())

  # A bid names the slot's counters as the page read them, so once the slot
  # moves on (a bid of theirs or someone else's takes it), the next press is a
  # new request.
  defp renew_key_if_moved(socket, before, latest) do
    if counters(before) == counters(latest), do: socket, else: new_key(socket)
  end

  defp counters(nil), do: nil
  defp counters(slot), do: {slot.active_generation, slot.next_revision}

  defp first_eligible(wordings) do
    case Enum.find(wordings, & &1.eligible?) do
      nil -> nil
      wording -> wording.version.id
    end
  end

  @doc "The least a bid in the chosen lane may be, as the page read the slot."
  def minimum(%{lane: lane, showing: showing, slot: slot, opening: opening}),
    do: BidDesk.minimum(lane, showing, slot, opening)

  defp number(text) do
    case Integer.parse(text || "") do
      {number, ""} when number in 1..3 -> number
      _other -> raise NotFoundError
    end
  end

  defp site(nil), do: nil

  defp site(id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, site} <- Ash.get(Site, id) do
      site
    else
      _missing -> raise NotFoundError
    end
  end

  defp lane("next_period"), do: :next_period
  defp lane(_immediate), do: :immediate

  attr(:showing, :map, required: true)
  attr(:slot, :map, required: true)
  attr(:number, :integer, required: true)
  attr(:now, DateTime, required: true)
  attr(:opening, :integer, required: true)
  attr(:returns, :integer, required: true)

  defp slot_card(assigns) do
    assigns = assign(assigns, next: assigns.showing && assigns.slot.next_bid)

    ~H"""
    <Regent.Structure.panel
      class="pb-bid-card pb-bid-current"
      role="region"
      aria-labelledby="pb-offers-bid-slot"
    >
      <header class="pb-bid-card-head">
        <h2 id="pb-offers-bid-slot">Agent Offer Slot {@number}</h2>
        <span class="pb-bid-state" data-state={if @showing, do: "placed", else: "empty"}>
          {if @showing, do: "Live", else: "Open"}
        </span>
      </header>
      <%= if @showing do %>
        <div class="pb-bid-current-copy"><.offer_copy version={@showing.version} /></div>
        <div class="pb-bid-owner">
          <.link navigate={Patchbay.Identity.AgentProfile.profile_url(@showing.owner)}>{@showing.owner.agent_name}</.link>
          <span title={"Ends #{moment(@showing.expires_at)}"}>
            <.bid_icon kind={:clock} /> {time_left(@showing.expires_at, @now)}
          </span>
        </div>
        <dl class="pb-bid-facts">
          <div>
            <dt>Current bid</dt><dd>{credits(@showing.amount_minor)}</dd>
          </div>
          <div>
            <dt>Replace from</dt><dd>
              {credits(Terms.replacement_minimum(@showing.amount_minor, @opening))}
            </dd>
          </div>
          <div>
            <dt>
              Responses
              <Regent.Primitives.tip id="pb-bid-returns-info" label="About response count">
                Responses carrying this Offer over its duration.
              </Regent.Primitives.tip>
            </dt><dd>{@returns}</dd>
          </div>
        </dl>
        <div class="pb-bid-next-summary">
          <.bid_icon kind={:clock} />
          <div>
            <strong>Next 72h</strong><span>Starts in {hours_until(@showing.expires_at, @now)}</span>
          </div>
          <span>{if @next, do: credits(@next.amount_minor), else: "No bids"}</span>
        </div>
        <details class="pb-bid-details">
          <summary>Slot details</summary>
          <p>Ends {moment(@showing.expires_at)}.</p>
          <p>
            Replacing it returns {credits(
              Terms.unused(@showing.amount_minor, @showing.expires_at, @now)
            )} to its owner.
          </p>
          <%= if @next do %>
            <p>
              Next period: <.link navigate={Patchbay.Identity.AgentProfile.profile_url(@next.owner)}>{@next.owner.agent_name}</.link>.
            </p>
            <.offer_copy version={@next.version} />
            <p>
              Next-period minimum: {credits(Terms.replacement_minimum(@next.amount_minor, @opening))}.
            </p>
          <% else %>
            <p>Next-period minimum: {credits(@opening)}.</p>
          <% end %>
        </details>
      <% else %>
        <div class="pb-bid-open-slot">
          <.bid_icon kind={:edit} /><p>Your Offer could be here.</p><span>72 hours · from {credits(
            @opening
          )}</span>
        </div>
      <% end %>
    </Regent.Structure.panel>
    """
  end

  # Small, decorative symbols for the bid controls; names stay in their labels.
  @bid_icons %{
    back: "M19 12H5m7-7-7 7 7 7",
    arrow: "M5 12h14m-7-7 7 7-7 7",
    bolt: "m13 2-9 12h7l-1 8 10-12h-7z",
    clock: "M12 8v4l3 2M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0",
    wallet: "M20 8V5H4v14h16v-5m0-6h-6v6h6zM16 11h.01",
    edit: "m16 3 5 5-12 12H4v-5zM13 6l5 5",
    check: "m5 12 4 4L19 6",
    chart: "M4 4v16h16M8 15v-3m5 3V8m5 7V5",
    info: "M12 11v6m0-10h.01M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0"
  }

  attr(:kind, :atom, required: true)

  defp bid_icon(assigns) do
    assigns = assign(assigns, path: Map.fetch!(@bid_icons, assigns.kind))

    ~H"""
    <svg
      class="pb-bid-icon"
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    ><path d={@path} /></svg>
    """
  end

  defp bid_state(:held), do: "Pending"
  defp bid_state(:leading), do: "Next up"
  defp bid_state(:placed), do: "Won"
  defp bid_state(:returned), do: "Returned"

  # Opens the header's Buy Credits dialog.
  defp buy_credits(assigns) do
    ~H"""
    <Regent.Primitives.button
      variant="quiet"
      type="button"
      phx-click={JS.dispatch("pb:credits-open", to: "#pb-credits")}
    >
      Buy Credits
    </Regent.Primitives.button>
    """
  end

  @doc "What pressing Bid holds, or what the amount needs."
  def held_words(amount) do
    case CreditAmount.parse(String.trim(amount || "")) do
      {:ok, minor} when minor > 0 -> "#{credits(minor)} will be held from your Credits now."
      _other -> Exception.message(BidRefused.exception(reason: :invalid_amount))
    end
  end

  # The bid page for another slot of the same market.
  defp bid_path(nil, number), do: ~p"/offers/bid?#{[slot: number]}"
  defp bid_path(site, number), do: ~p"/offers/bid?#{[site: site.id, slot: number]}"

  @doc "The slot's name: Global's or its site's, and its number."
  def label(nil, number), do: "Global · Slot #{number}"
  def label(site, number), do: "#{site_name(site)} · Slot #{number}"

  @doc "Where one of the advertiser's bids stands, in words."
  def standing(%Bid{status: :held}), do: "Credits held · being compared with other bids"
  def standing(%Bid{status: :leading}), do: "Leading the next period · Credits held"
  def standing(%Bid{status: :placed, placement: placement}), do: "Won · " <> ran(placement)

  def standing(%Bid{status: :returned} = bid),
    do: "Not filled · #{credits(bid.amount_minor)} returned. #{returned(bid.return_reason)}"

  defp ran(%{status: :active, expires_at: at}), do: "showing until #{moment(at)}"
  defp ran(%{status: :expired}), do: "ran its full time"

  defp ran(%{status: :bought_out, returned_minor: back}),
    do: "replaced by a higher bid; #{credits(back)} came back"

  defp ran(%{status: :removed_for_policy}),
    do: "removed by a moderator for breaking the rules; nothing came back"

  defp returned(:outbid), do: "A higher bid won."
  defp returned(:stale), do: "The slot moved on before it was decided."
  defp returned(:ineligible), do: "Its wording could not be shown when its turn came."
  defp returned(:next_leader_replaced), do: "A higher next-period bid took the lead."
  defp returned(:cancelled_by_buyout), do: "The Offer it was waiting behind was bought out."
  defp returned(:placement_removed), do: "A moderator removed the Offer it was waiting on."

  @doc "Where a wording's check for this market stands, when it can't be bid yet."
  def fit_words(%{fit: nil}), do: nil
  def fit_words(%{fit: review}), do: Create.standing(review)

  @doc "Where a wording's safety screening stands."
  def safety_words(%{safety: nil}), do: "Waiting for screening."
  def safety_words(%{safety: review}), do: Create.standing(review)

  @doc false
  def safety_approved?(%{safety: %{approved?: true}}), do: true
  def safety_approved?(_wording), do: false
end
