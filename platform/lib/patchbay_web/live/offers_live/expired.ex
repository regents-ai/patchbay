defmodule PatchbayWeb.OffersLive.Expired do
  @moduledoc """
  A signed-in advertiser's past Offers: every placement that has ended,
  with why it ended and where its USDC went (paid, returned, used,
  forfeited, and what it cost in the end), newest first; and every bid that
  did not win, which came back in full, with why.

  Both lists come from the placement and bid records, read as their owner,
  a page at a time.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  import PatchbayWeb.OffersLive.Markets,
    only: [usdc: 1, duration: 1, offer_copy: 1, slot_label: 1]

  require Ash.Query

  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.Placement

  @page 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Past Offers", signed_in?: not is_nil(socket.assigns.current_profile))
      |> stream(:ended, [])
      |> stream(:returned, [])

    if socket.assigns.signed_in? do
      {:ok, socket |> read(:ended, nil) |> read(:returned, nil)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("more", %{"list" => list}, socket) when list in ["ended", "returned"] do
    list = String.to_existing_atom(list)
    {:noreply, read(socket, list, socket.assigns[cursor(list)])}
  end

  defp read(socket, list, after_cursor) do
    page = [limit: @page] ++ if(after_cursor, do: [after: after_cursor], else: [])

    %{results: records, more?: more?} =
      list
      |> query(socket.assigns.current_profile)
      |> Ash.read!(page: page)

    socket
    |> stream(list, records)
    |> assign([{more(list), more?}])
    |> assign_cursor(list, List.last(records))
  end

  defp query(:ended, profile) do
    Placement
    |> Ash.Query.for_read(:mine, %{}, actor: profile)
    |> Ash.Query.filter(status != :active)
    |> Ash.Query.load(version: [], slot: [market: :site])
  end

  defp query(:returned, profile) do
    Bid
    |> Ash.Query.for_read(:mine, %{}, actor: profile)
    |> Ash.Query.filter(status == :returned)
    |> Ash.Query.load(version: [], slot: [market: :site])
  end

  defp assign_cursor(socket, _list, nil), do: socket

  defp assign_cursor(socket, list, last),
    do: assign(socket, [{cursor(list), last.__metadata__.keyset}])

  defp cursor(:ended), do: :ended_cursor
  defp cursor(:returned), do: :returned_cursor

  defp more(:ended), do: :ended_more?
  defp more(:returned), do: :returned_more?

  defp ended(:expired), do: "Ran its full time"
  defp ended(:bought_out), do: "Replaced by a higher bid"
  defp ended(:removed_for_policy), do: "Removed by a moderator"

  defp returned(:outbid), do: "A higher bid won the slot."
  defp returned(:stale), do: "The slot changed before the bids were compared."
  defp returned(:ineligible), do: "Its wording could not be shown when its turn came."
  defp returned(:next_leader_replaced), do: "A higher bid took the next period."

  defp returned(:cancelled_by_buyout),
    do: "The Offer it was waiting behind was replaced by a higher bid."

  defp returned(:placement_removed), do: "A moderator removed the Offer it was bidding against."

  defp ran_for(placement),
    do: duration(DateTime.diff(placement.ended_at, placement.starts_at, :second))
end
