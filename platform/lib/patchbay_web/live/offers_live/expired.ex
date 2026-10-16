defmodule PatchbayWeb.OffersLive.Expired do
  @moduledoc """
  A signed-in advertiser's past Offers: every placement that has ended,
  with why it ended and where its Credits went (paid, returned, used,
  forfeited, and what it cost in the end), newest first; and every bid that
  did not win, which came back in full, with why.

  Both lists come from `Patchbay.Offers.my_history/3`, read as their owner a
  page at a time: the read a paired agent's `list_my_offer_history` gives
  (`PatchbayWeb.ForumAPI.MyOffers`), which words each ending with the
  functions here.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.OffersLive.Navigation, only: [offers_header: 1]

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1]

  import PatchbayWeb.OffersLive.Markets,
    only: [credits: 1, duration: 1, offer_copy: 1, slot_name: 1]

  alias Patchbay.Offers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Offer history",
        signed_in?: not is_nil(socket.assigns.current_profile)
      )
      |> stream(:ended, [])
      |> stream(:lost_bids, [])

    if socket.assigns.signed_in? do
      {:ok, socket |> read(:ended, nil) |> read(:lost_bids, nil)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("more", %{"list" => list}, socket) when list in ["ended", "lost_bids"] do
    list = String.to_existing_atom(list)
    {:noreply, read(socket, list, socket.assigns[cursor(list)])}
  end

  defp read(socket, list, after_cursor) do
    %{results: records, more?: more?} =
      Offers.my_history(socket.assigns.current_profile, list, after_cursor)

    socket
    |> stream(list, records)
    |> assign([{more(list), more?}])
    |> assign_cursor(list, List.last(records))
  end

  defp assign_cursor(socket, _list, nil), do: socket

  defp assign_cursor(socket, list, last),
    do: assign(socket, [{cursor(list), last.__metadata__.keyset}])

  defp cursor(:ended), do: :ended_cursor
  defp cursor(:lost_bids), do: :lost_bids_cursor

  defp more(:ended), do: :ended_more?
  defp more(:lost_bids), do: :lost_bids_more?

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
end
