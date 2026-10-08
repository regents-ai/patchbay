defmodule PatchbayWeb.OffersLive.BidDesk do
  @moduledoc """
  One advertiser at one slot: the slot as it stands, their Credits, their
  wordings and whether each may be bid there, their bids on it, and placing
  a bid. The bid page and the agent tools read and bid through here, so an
  agent acting for a signed-in person does exactly what the page's Bid
  button does.
  """

  require Ash.Query

  alias Patchbay.Credits
  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms
  alias PatchbayWeb.OffersLive.Markets
  alias RegentCredits.Errors.NotEnoughCredits

  @doc "Global's market (`site` nil) or the site's, if it has been opened, with its slots."
  @spec market(map() | nil, term()) :: map() | nil
  def market(nil, window), do: Markets.global(window)
  def market(site, window), do: Markets.site_markets([site.id], window)[site.id]

  @doc "The slot of `number` in `market`, or nil while the market has not been opened."
  @spec slot(map() | nil, 1..3) :: map() | nil
  def slot(nil, _number), do: nil
  def slot(market, number), do: Enum.find(market.slots, &(&1.number == number))

  @doc "The placement showing in `slot` at `now`, if any."
  @spec showing(map() | nil, DateTime.t()) :: map() | nil
  def showing(%{active_placement: %{} = placement}, now),
    do: if(Markets.showing?(placement, now), do: placement)

  def showing(_slot, _now), do: nil

  @doc """
  The least a bid in `lane` may be: the replacement minimum over what holds
  the lane, else the market's opening minimum. The next-period lane opens
  only behind an Offer that is showing.
  """
  @spec minimum(:immediate | :next_period, map() | nil, map() | nil, pos_integer()) ::
          pos_integer()
  def minimum(:immediate, %{amount_minor: amount}, _slot, opening),
    do: Terms.replacement_minimum(amount, opening)

  def minimum(:next_period, %{}, %{next_bid: %{amount_minor: amount}}, opening),
    do: Terms.replacement_minimum(amount, opening)

  def minimum(_lane, _showing, _slot, opening), do: opening

  @doc """
  The terms a bid is placed under, in the words the page shows beside Bid:
  how bids are compared, then each lane's. The next-period lane has terms
  only behind an Offer that is showing.
  """
  @spec terms(map() | nil) :: %{
          holds: String.t(),
          compared: String.t(),
          immediate: [String.t()],
          next_period: String.t() | nil
        }
  def terms(showing) do
    %{
      holds: "A bid holds its full amount from your Credits the moment it is accepted.",
      compared:
        "Bids placed within two seconds of each other are compared together. The highest " <>
          "wins, and every other bid comes back to your Credits in full.",
      immediate: [
        if(showing,
          do:
            "If yours wins, it replaces the Offer showing now and runs for 72 hours, and " <>
              "that Offer's owner gets back their unused share.",
          else: "If yours wins, it shows for up to 72 hours."
        ),
        "A higher bid can replace yours at any time; you then get back your unused share. " <>
          "If a moderator removes your Offer for breaking the rules, nothing comes back."
      ],
      next_period:
        showing &&
          "Your Credits are held now. Your Offer starts for a fresh 72 hours when the " <>
            "current placement naturally expires, or immediately if a moderator removes it. " <>
            "If the current placement is bought out normally, your held Credits return in " <>
            "full. A higher next-period bid also returns your hold in full. You cannot " <>
            "voluntarily cancel this commitment."
    }
  end

  @doc "What a signed-in advertiser has at this slot: Credits, wordings and bids."
  @spec mine(map() | nil, map() | nil, map() | nil, DateTime.t()) :: map()
  def mine(nil, _market, _slot, _now), do: %{balance: nil, wordings: [], bids: []}

  def mine(profile, market, slot, now) do
    %{
      balance: balance(profile),
      wordings: wordings(profile, market, now),
      bids: if(slot, do: bids(profile, slot), else: [])
    }
  end

  @doc """
  Places a bid for `profile` on the slot numbered `number` of Global's
  market (`site` nil) or the site's, opening the site's market if this is
  its first bid. The counters are the slot's as the bidder read them; a
  slot that moved on since refuses the bid.
  """
  @spec place(map(), map() | nil, 1..3, map()) :: {:ok, Bid.t()} | {:error, term()}
  def place(profile, site, number, bid) do
    Offers.submit_bid(
      %{
        slot_id: slot_id(site, number),
        lane: bid.lane,
        amount: String.trim(bid.amount || ""),
        version_id: bid.version_id,
        target_generation: bid.generation,
        target_next_revision: bid.next_revision,
        idempotency_key: bid.key
      },
      actor: profile
    )
  end

  @doc """
  Why a bid was not placed, in the words the page and agents both show:
  short of Credits (more Credits would cover it), refused by the market, or
  not placed for a reason a retry may clear. Nothing is held in any case.
  """
  @spec refusal(term()) :: {:not_enough_credits | :refused | :unavailable, String.t()}
  def refusal(%Ash.Error.Invalid{errors: [%NotEnoughCredits{shortfall: shortfall} | _]}),
    do:
      {:not_enough_credits,
       "You need #{CreditAmount.format(CreditAmount.from_credits(shortfall))} more Credits."}

  # The market's own words, without the trail of where in the code it was
  # refused.
  def refusal(%Ash.Error.Invalid{errors: [%BidRefused{} = refused | _]}),
    do: {:refused, Exception.message(%{refused | bread_crumbs: []})}

  def refusal(%Ash.Error.Invalid{errors: [%{field: :version_id} | _]}),
    do: {:refused, "Choose one of your approved wordings."}

  def refusal(_error),
    do:
      {:unavailable, "That bid could not be placed, and nothing was held. Try again in a moment."}

  @doc """
  Asks whether `version_id` fits the site's market, opening the market if
  this is the first time it is needed.
  """
  @spec ask_fit(map(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def ask_fit(profile, %{} = site, version_id),
    do: Offers.request_market_review(version_id, open_market(site).id, actor: profile)

  defp open_market(nil), do: Offers.global_market!()

  # Opening a site's market only makes its three empty slots, which every
  # visitor already sees as empty, so it skips authorization deliberately.
  defp open_market(site), do: Offers.open_site_market!(site.id, authorize?: false)

  defp slot_id(site, number) do
    market = open_market(site)

    # Slots are public.
    Slot
    |> Ash.Query.filter(market_id == ^market.id and number == ^number)
    |> Ash.read_one!()
    |> Map.fetch!(:id)
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
end
