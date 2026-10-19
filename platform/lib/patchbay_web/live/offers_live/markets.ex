defmodule PatchbayWeb.OffersLive.Markets do
  @moduledoc """
  Offer markets as the public pages read and show them: Global and the
  markets of given sites, and the small pieces every Offers page shows.

  Every read takes the moment the page was read and the 72-hour window
  ending then, so the times, prices and counts on a page agree. Nothing
  private is shown: owners appear by their public agent name.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [site_name: 1]

  require Ash.Query

  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Market
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Slot

  @doc "Global with its three slots."
  def global(window) do
    Market
    |> Ash.Query.for_read(:global)
    |> Ash.Query.load(slots: slots(window))
    # A slot's next-period copy is shown before it runs, so this read passes
    # the wordings' owner-only policy deliberately: a slot only ever points
    # at copy that is placed or leading.
    |> Ash.read_one!(authorize?: false)
  end

  @doc "The markets of `site_ids` that have been opened, by site id."
  def site_markets([], _window), do: %{}

  def site_markets(site_ids, window) do
    Market
    |> Ash.Query.filter(site_id in ^site_ids)
    |> Ash.Query.load(slots: slots(window))
    # As above.
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.site_id, &1})
  end

  defp slots(window) do
    Slot
    |> Returns.count_slot_returns(window)
    |> Ash.Query.load(
      active_placement: [:owner, version: [:blocked_at]],
      next_bid: [:owner, version: [:blocked_at]]
    )
  end

  @doc "An amount of Credits in words."
  def credits(minor), do: "#{CreditAmount.format(minor)} Credits"

  @doc "How long is left until `expires_at`, in words."
  def time_left(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds < 60 -> "under a minute left"
      seconds -> duration(seconds) <> " left"
    end
  end

  @doc "Time until the current Offer ends, rounded up to hours."
  def hours_until(expires_at, now) do
    seconds = max(DateTime.diff(expires_at, now, :second), 0)

    case seconds do
      seconds when seconds < 3600 -> "under 1 hour"
      3600 -> "1 hour"
      seconds -> "about #{div(seconds + 3599, 3600)} hours"
    end
  end

  @doc "Where a slot is, in words: its site or Global, and its number."
  def slot_label(%{number: number, market: %{scope: :global}}), do: "Global · Slot #{number}"

  def slot_label(%{number: number, market: %{site: site}}),
    do: "#{site_name(site)} · Slot #{number}"

  attr(:slot, :map, required: true, doc: "the slot, with its market")
  attr(:id, :string, required: true, doc: "unique on the page; names the explanation")

  @doc "A slot's name, with what a Global slot is when it is one."
  def slot_name(assigns) do
    ~H"""
    <span class="pb-offers-tip-host">
      {slot_label(@slot)} <.global_tip :if={@slot.market.scope == :global} id={@id} />
    </span>
    """
  end

  attr(:id, :string, required: true, doc: "unique on the page; names the explanation")

  @doc """
  A small question mark that explains Global Agent Offer Slots on hover or
  focus. The explanation opens from the start of the nearest
  `.pb-offers-tip-host`, so it stays on screen wherever the mark falls.
  """
  def global_tip(assigns) do
    ~H"""
    <span class="pb-offers-tip">
      <button
        type="button"
        class="pb-offers-tip-button"
        aria-label="About Global Agent Offer Slots"
        aria-describedby={@id}
      >
        ?
      </button>
      <span role="tooltip" id={@id} class="pb-offers-tip-text">
        Global Agent Offer Slots are filled in only if site-specific Agent Offers are not active.
      </span>
    </span>
    """
  end

  @doc "A length of time in days, hours and minutes."
  def duration(seconds) do
    minutes = div(seconds, 60)

    case {div(minutes, 1440), div(rem(minutes, 1440), 60), rem(minutes, 60)} do
      {0, 0, m} -> "#{m} min"
      {0, h, m} -> "#{h} h #{m} min"
      {d, h, _m} -> "#{d} d #{h} h"
    end
  end

  @doc "Whether a placement is showing at the moment the page was read."
  def showing?(placement, now),
    do: placement.status == :active and DateTime.after?(placement.expires_at, now)

  attr(:version, :map, required: true)

  @doc "An Offer's words, or that Patchbay blocked them."
  def offer_copy(assigns) do
    ~H"""
    <p :if={@version.blocked_at} class="pb-offmod-blocked">
      Blocked by Patchbay. This Offer is not shown.
    </p>
    <blockquote :if={!@version.blocked_at} class="pb-offmod-offer">{@version.text}</blockquote>
    """
  end
end
