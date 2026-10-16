defmodule PatchbayWeb.OffersLive.Mine do
  @moduledoc """
  The figures and words for a person's own Offers, worked out once for the
  Active and History tabs and for a paired agent's read of them
  (`PatchbayWeb.ForumAPI.MyOffers`), so the two always agree.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Terms

  import PatchbayWeb.OffersLive.Markets, only: [duration: 1]

  @doc "What a showing placement's owner would get back if it were bought out at `now`."
  def unused(placement, now), do: Terms.unused(placement.amount_minor, placement.expires_at, now)

  @doc "The least a bid must be to buy out a placement, or to outbid a leading bid."
  def buyout(record),
    do:
      Terms.replacement_minimum(
        record.amount_minor,
        Offers.opening_minimum_minor(record.slot.market)
      )

  @doc """
  When a leading bid's period starts: when its slot's running placement
  ends, or nil while the slot is free.
  """
  def upcoming_start(%{slot: %{active_placement: nil}}), do: nil
  def upcoming_start(%{slot: %{active_placement: placement}}), do: placement.expires_at

  @doc "When a leading bid's period ends, or nil while its slot is free."
  def upcoming_end(bid) do
    case upcoming_start(bid) do
      nil -> nil
      starts_at -> Terms.expires_at(starts_at)
    end
  end

  @doc "Why a placement ended, in words."
  def why_ended(:expired), do: "Ran its full time"
  def why_ended(:bought_out), do: "Replaced by a higher bid"
  def why_ended(:removed_for_policy), do: "Removed by a moderator"

  @doc "Why a bid did not win and came back, in words."
  def why_returned(:outbid), do: "A higher bid won the slot."
  def why_returned(:stale), do: "The slot changed before the bids were compared."
  def why_returned(:ineligible), do: "Its wording could not be shown when its turn came."
  def why_returned(:next_leader_replaced), do: "A higher bid took the next period."

  def why_returned(:cancelled_by_buyout),
    do: "The Offer it was waiting behind was replaced by a higher bid."

  def why_returned(:placement_removed),
    do: "A moderator removed the Offer it was bidding against."

  @doc "How long an ended placement ran, in words."
  def ran_for(placement),
    do: duration(DateTime.diff(placement.ended_at, placement.starts_at, :second))

  @doc "What an ended placement cost in the end: what was paid, less what came back."
  def cost(placement), do: placement.amount_minor - placement.returned_minor
end
