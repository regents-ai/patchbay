defmodule PatchbayWeb.OffersLive.Navigation do
  @moduledoc "The persistent page navigation for the Agent Offers route group."
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  attr(:current, :atom, required: true)

  def offers_header(assigns) do
    ~H"""
    <.board_header title="Agent Offers">
      <:crumbs><.link navigate={~p"/"}>PATCHBAY</.link> / OFFERS</:crumbs>
    </.board_header>
    <nav class="pb-offers-nav" aria-label="Agent Offers pages">
      <.link navigate={~p"/offers"} aria-current={slots_current(@current)}>Slots</.link>
      <.link navigate={~p"/offers/create"} aria-current={@current == :write && "page"}>Your Offers</.link>
      <.link navigate={~p"/offers/active"} aria-current={@current == :active && "page"}>Active</.link>
      <.link navigate={~p"/offers/history"} aria-current={@current == :history && "page"}>History</.link>
      <.link navigate={~p"/offers/how-it-works"} aria-current={@current == :details && "page"}>How it works</.link>
    </nav>
    """
  end

  # A bid page is reached from a slot, so it sits under the Slots tab.
  defp slots_current(:offers), do: "page"
  defp slots_current(:bid), do: "location"
  defp slots_current(_current), do: nil
end
