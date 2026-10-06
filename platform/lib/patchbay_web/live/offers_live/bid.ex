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
  topic and read the slot, the bids and the balance again.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, moment: 1, site_name: 1, site_path: 1]

  import PatchbayWeb.OffersLive.Markets, only: [credits: 1, offer_slot: 1]

  require Ash.Query

  alias Patchbay.Credits
  alias Patchbay.Forum.Site
  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.OffersLive.Create
  alias PatchbayWeb.OffersLive.Markets
  alias RegentCredits.Errors.NotEnoughCredits

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Slot.topic())
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Review.topic())
    end

    {:ok, assign(socket, page_title: "Bid on an Offer slot", problem: nil)}
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

  @impl true
  def handle_event("change", %{"bid" => params}, socket) do
    lane = lane(params["lane"])
    socket = assign(socket, version_id: params["version_id"], problem: nil)

    {:noreply,
     if(lane == socket.assigns.lane,
       do: socket |> assign(amount: params["amount"]) |> new_key(),
       else: socket |> assign(lane: lane) |> assign_minimum() |> prefill()
     )}
  end

  def handle_event("bid", %{"bid" => params}, socket) do
    socket =
      assign(socket,
        lane: lane(params["lane"]),
        version_id: params["version_id"],
        amount: params["amount"]
      )

    case place(socket) do
      {:ok, _bid} -> {:noreply, socket |> assign(problem: nil) |> read()}
      {:error, error} -> {:noreply, socket |> assign(problem: words(error)) |> read()}
    end
  end

  def handle_event("ask_fit", %{"version_id" => id}, socket) do
    market = open_market(socket)

    case Offers.request_market_review(id, market.id, actor: socket.assigns.current_profile) do
      {:ok, _review} ->
        {:noreply, socket |> assign(problem: nil) |> read()}

      {:error, _error} ->
        {:noreply, assign(socket, problem: "That could not be asked. Try again.")}
    end
  end

  defp place(socket) do
    %{slot: slot, lane: lane, version_id: version_id, amount: amount, key: key} = socket.assigns
    slot_id = if slot, do: slot.id, else: open_slot(socket).id

    Offers.submit_bid(
      %{
        slot_id: slot_id,
        lane: lane,
        amount: String.trim(amount || ""),
        version_id: version_id,
        # As the page read them; a slot not yet opened starts at nothing.
        target_generation: if(slot, do: slot.active_generation, else: 0),
        target_next_revision: if(slot, do: slot.next_revision, else: 0),
        idempotency_key: key
      },
      actor: socket.assigns.current_profile
    )
  end

  defp open_market(%{assigns: %{market: %{} = market}}), do: market

  defp open_market(%{assigns: %{site: site}}) do
    # Opening a site's market only makes its three empty slots, which every
    # visitor already sees as empty, so it skips authorization deliberately.
    Offers.open_site_market!(site.id, authorize?: false)
  end

  defp open_slot(socket) do
    market = open_market(socket)
    number = socket.assigns.number

    # Slots are public.
    Slot
    |> Ash.Query.filter(market_id == ^market.id and number == ^number)
    |> Ash.read_one!()
  end

  defp read(socket) do
    %{site: site, number: number, current_profile: profile} = socket.assigns
    now = DateTime.utc_now()
    window = Returns.window(now)

    market =
      if site,
        do: Markets.site_markets([site.id], window)[site.id],
        else: Markets.global(window)

    slot = market && Enum.find(market.slots, &(&1.number == number))

    socket
    |> assign(now: now, market: market, slot: slot, opening: Offers.opening_minimum_minor(market))
    |> assign(showing: showing(slot, now))
    |> assign(mine(profile, market, slot, now))
    |> assign_minimum()
  end

  defp assign_minimum(socket), do: assign(socket, minimum: minimum(socket.assigns))

  defp showing(nil, _now), do: nil

  defp showing(slot, now) do
    placement = slot.active_placement
    if placement && Markets.showing?(placement, now), do: placement
  end

  defp mine(nil, _market, _slot, _now), do: %{balance: nil, wordings: [], bids: []}

  defp mine(profile, market, slot, now) do
    %{
      balance: balance(profile),
      wordings: wordings(profile, market, now),
      bids: if(slot, do: bids(profile, slot), else: [])
    }
  end

  defp balance(profile) do
    case Credits.spender(profile) do
      {:ok, _spender} -> RegentCredits.balance(profile.privy_user_id)
      :not_linked -> :not_linked
    end
  end

  # Each current wording with whether it may be bid here now, and if not,
  # where its check for this market stands.
  defp wordings(profile, market, now) do
    reviews = Ash.Query.load(Review, [:approved?, market: :site])

    versions =
      [actor: profile, load: [current_version: [reviews: reviews]]]
      |> Offers.my_creatives!()
      |> Enum.reject(&(&1.archived_at || &1.current_version.blocked_at))
      |> Enum.map(&{&1, &1.current_version})

    eligible = eligible(profile, market, Enum.map(versions, fn {_c, v} -> v.id end), now)

    Enum.map(versions, fn {creative, version} ->
      %{
        creative: creative,
        version: version,
        eligible?: version.id in eligible,
        fit: market && Enum.find(version.reviews, &(&1.market_id == market.id))
      }
    end)
  end

  defp eligible(_profile, nil, _ids, _now), do: []
  defp eligible(_profile, _market, [], _now), do: []

  defp eligible(profile, market, ids, now) do
    CreativeVersion
    |> Ash.Query.for_read(
      :eligible,
      %{market_id: market.id, global: market.scope == :global, at: now},
      actor: profile
    )
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp bids(profile, slot) do
    Bid
    |> Ash.Query.for_read(:mine, %{}, actor: profile)
    |> Ash.Query.filter(slot_id == ^slot.id)
    |> Ash.Query.load([:version, :placement])
    |> Ash.read!(page: [limit: 10])
    |> Map.fetch!(:results)
  end

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
  def minimum(%{lane: :immediate, showing: %{amount_minor: amount}, opening: opening}),
    do: Terms.replacement_minimum(amount, opening)

  def minimum(%{
        lane: :next_period,
        slot: %{next_bid: %{amount_minor: amount}},
        opening: opening
      }),
      do: Terms.replacement_minimum(amount, opening)

  def minimum(%{opening: opening}), do: opening

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

  defp words(%Ash.Error.Invalid{errors: [%NotEnoughCredits{shortfall: shortfall} | _]}),
    do: "You need #{CreditAmount.format(CreditAmount.from_credits(shortfall))} more Credits."

  defp words(%Ash.Error.Invalid{errors: [%BidRefused{} = refused | _]}),
    do: Exception.message(refused)

  defp words(%Ash.Error.Invalid{errors: [%{field: :version_id} | _]}),
    do: "Choose one of your approved wordings."

  defp words(_error),
    do: "That bid could not be placed, and nothing was held. Try again in a moment."

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
