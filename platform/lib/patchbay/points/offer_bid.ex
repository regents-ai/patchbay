defmodule Patchbay.Points.OfferBid do
  @moduledoc """
  Regent Points' check of an Offer bid: a bid earns once its Offer starts
  showing, for the person whose Credits it held, and for their agent when the
  agent bid. Both are kept on the bid's Credits hold as they stood when the
  bid was made. A bid that led and was replaced before it showed has no
  placement and earns nothing.
  """

  require Ash.Query

  alias Patchbay.Credits
  alias Patchbay.Offers.Placement
  alias Patchbay.Points.Beneficiary

  def verify(%{"source_event_key" => bid_id}) do
    with {:ok, placement} <- placement(bid_id),
         {:ok, hold} <- hold(bid_id),
         {:ok, who} <- Beneficiary.of(hold.privy_user_id, hold.pairing_id) do
      {:ok, facts(bid_id, placement, hold, who)}
    end
  end

  defp placement(bid_id) do
    # No person is asking: Points' server check reads the committed placement.
    case Placement |> Ash.Query.filter(bid_id == ^bid_id) |> Ash.read_one(authorize?: false) do
      {:ok, %Placement{} = placement} -> {:ok, placement}
      {:ok, nil} -> {:error, :bid_not_placed}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp hold(bid_id) do
    query = Ash.Query.filter(RegentCredits.Hold, site == ^Credits.site() and key == ^bid_id)

    case RegentCredits.holds(query: query, actor: Credits.site_actor()) do
      {:ok, [hold]} -> {:ok, hold}
      {:ok, []} -> {:error, :bid_hold_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp facts(bid_id, placement, hold, who) do
    Map.merge(who, %{
      source_app: Patchbay.Points.app(),
      source_kind: "offer_bid",
      source_event_key: bid_id,
      source_action_at: hold.held_at,
      qualified_at: placement.starts_at,
      evidence_ref: "offer_placement:" <> placement.id
    })
  end
end
