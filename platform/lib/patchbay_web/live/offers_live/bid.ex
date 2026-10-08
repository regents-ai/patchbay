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
  raises an amount or changes a lane on its own. Until a detail changes,
  every press sends the same request key, so a repeat answers with the
  first bid and never holds twice.

  A site's market is opened when it is first needed: a bid, or asking
  whether a wording fits the site. Open pages hear `Patchbay.Offers.Slot`'s
  topic and read the slot, the bids and the balance again, and read the
  balance again whenever the advertiser's Credits move.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, moment: 1, site_name: 1, site_path: 1]

  import PatchbayWeb.OffersLive.Markets, only: [credits: 1, offer_slot: 1]

  alias Patchbay.Credits
  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Slot
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

    {:ok, assign(socket, page_title: "Bid on an Offer slot", problem: nil, short?: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    number = number(params["slot"])
    site = site(params["site"])

    {:noreply,
     socket
     |> assign(number: number, site: site, lane: :immediate, version_id: nil, amount: nil)
     |> read()
     |> prefill()}
  end

  @impl true
  def handle_info(:offer_markets_changed, socket), do: {:noreply, read(socket)}

  def handle_info(:offer_reviews_changed, socket), do: {:noreply, read(socket)}

  def handle_info(:credits_changed, socket), do: {:noreply, read(socket)}

  @impl true
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
      {:ok, _bid} ->
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
  defp follow_credits(profile) do
    case profile && Credits.spender(profile) do
      {:ok, _spender} ->
        :ok =
          Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(profile.privy_user_id))

      _not_linked ->
        :ok
    end
  end

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

    socket
    |> assign(now: now, market: market, slot: slot, opening: Offers.opening_minimum_minor(market))
    |> assign(showing: showing, terms: BidDesk.terms(showing))
    |> assign(BidDesk.mine(profile, market, slot, now))
    |> assign_minimum()
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

  @doc false
  def not_linked_words, do: Exception.message(BidRefused.exception(reason: :not_linked))

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
end
