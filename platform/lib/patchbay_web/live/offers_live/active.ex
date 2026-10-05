defmodule PatchbayWeb.OffersLive.Active do
  @moduledoc """
  What is running now. A signed-in advertiser sees their own Offers first:
  those showing, with what they would get back if replaced now; those
  leading the next period, with when they would start; and bids still in
  their two-second comparison, marked as not yet decided.

  Below, for everyone, the site markets with an Offer showing, ranked by
  their highest showing bid. General is not ranked among them; the market
  list shows it on its own.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, moment: 1, site_name: 1, site_path: 1]

  import PatchbayWeb.OffersLive.Markets,
    only: [usdc: 1, offer_copy: 1, offer_slot: 1, slot_label: 1, time_left: 2, top_bid: 2]

  require Ash.Query

  import Ash.Expr, only: [expr: 1]

  alias Patchbay.Offers
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.Placement
  alias Patchbay.Offers.Returns
  alias Patchbay.Offers.Terms
  alias PatchbayWeb.OffersLive.Markets

  @mine 50

  @impl true
  def mount(_params, _session, socket) do
    as_of = DateTime.utc_now()
    window = Returns.window(as_of)
    profile = socket.assigns.current_profile

    {:ok,
     assign(socket,
       page_title: "Active Offers",
       as_of: as_of,
       ranked: Markets.ranked(window),
       mine: if(profile, do: mine(profile, as_of))
     )}
  end

  defp mine(profile, as_of) do
    %{
      showing:
        read(Placement, profile, expr(status == :active and expires_at > ^as_of),
          version: [],
          slot: [market: :site]
        ),
      leading:
        read(Bid, profile, expr(status == :leading),
          version: [],
          slot: [:active_placement, market: :site]
        ),
      waiting: read(Bid, profile, expr(status == :held), version: [], slot: [market: :site])
    }
  end

  defp read(resource, profile, filter, load) do
    resource
    |> Ash.Query.for_read(:mine, %{}, actor: profile)
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(load)
    |> Ash.read!(page: [limit: @mine])
    |> Map.fetch!(:results)
  end

  defp opening(market), do: Offers.opening_minimum_minor(market)

  defp unused(placement, now), do: Terms.unused(placement.amount_minor, placement.expires_at, now)
end
