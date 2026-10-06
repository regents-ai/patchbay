defmodule PatchbayWeb.OffersLive.Markets do
  @moduledoc """
  Offer markets as the public pages read and show them: Global, the
  markets of given sites, and the site markets with something showing,
  highest bid first; and one numbered slot as every page shows it.

  Every read takes the moment the page was read and the 72-hour window
  ending then, so the times, prices and counts on a page agree. Nothing
  private is shown: owners appear by their public agent name.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1, site_name: 1]

  require Ash.Query
  require Ash.Sort

  import Ash.Expr, only: [expr: 1]

  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Market
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms

  @ranked 50

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

  @doc """
  The site markets with an Offer showing at `as_of`, ranked by their highest
  showing bid, ties by the site's address and then its id. At most the
  first #{@ranked}. Global is never ranked among them.
  """
  def ranked({_since, as_of} = window) do
    showing = expr(status == :active and expires_at > ^as_of)

    top_bid =
      Ash.Sort.expr_sort(
        max(slots.active_placement, field: :amount_minor, query: [filter: ^showing]),
        :integer
      )

    Market
    |> Ash.Query.filter(scope == :site and exists(slots.active_placement, ^showing))
    |> Ash.Query.sort([
      {top_bid, :desc},
      {Ash.Sort.expr_sort(site.origin, :string), :asc},
      {:site_id, :asc}
    ])
    |> Ash.Query.limit(@ranked)
    |> Ash.Query.load([:site, slots: slots(window)])
    # As above.
    |> Ash.read!(authorize?: false)
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
  def credits(minor), do: "#{CreditAmount.format(minor)} Credits"

  @doc false
  def responses(1), do: "response"
  def responses(_count), do: "responses"

  @doc "How long is left until `expires_at`, in words."
  def time_left(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds < 60 -> "under a minute left"
      seconds -> duration(seconds) <> " left"
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

  @doc "The highest bid showing in `market`'s slots at `now`."
  def top_bid(market, now) do
    market.slots
    |> Enum.map(& &1.active_placement)
    |> Enum.filter(&(&1 && showing?(&1, now)))
    |> Enum.map(& &1.amount_minor)
    |> Enum.max()
  end

  @doc "Whether a placement is showing at the moment the page was read."
  def showing?(placement, now),
    do: placement.status == :active and DateTime.after?(placement.expires_at, now)

  attr(:slot, :map, required: true, doc: "the slot, or nil for a market not yet opened")
  attr(:number, :integer, required: true)
  attr(:opening, :integer, required: true, doc: "the market's opening minimum, minor units")
  attr(:now, DateTime, required: true, doc: "the moment the page was read")
  attr(:opportunities, :integer, default: nil, doc: "Global slots only")

  attr(:bid_path, :string,
    default: nil,
    doc: "where to bid on this slot, when the page offers it"
  )

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

      <.link :if={@bid_path} navigate={@bid_path} class="rg-button rg-button--secondary">
        Bid on this slot
      </.link>
    </li>
    """
  end

  attr(:profile, :map, required: true)

  defp owner(assigns) do
    ~H"""
    <.link navigate={AgentProfile.profile_url(@profile)}>{@profile.agent_name}</.link>
    """
  end

  attr(:version, :map, required: true)

  @doc "An Offer's words, or that a moderator blocked them."
  def offer_copy(assigns) do
    ~H"""
    <p :if={@version.blocked_at} class="pb-offmod-blocked">
      Blocked by a moderator. This Offer is not shown.
    </p>
    <blockquote :if={!@version.blocked_at} class="pb-offmod-offer">{@version.text}</blockquote>
    """
  end
end
