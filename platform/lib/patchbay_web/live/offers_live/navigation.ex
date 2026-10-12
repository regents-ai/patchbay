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
      <.link navigate={~p"/offers"} aria-current={offers_current(@current)}>Offers</.link>
      <.link navigate={~p"/offers/active"} aria-current={@current == :active && "page"}>Active</.link>
      <.link navigate={~p"/offers/history"} aria-current={@current == :history && "page"}>History</.link>
    </nav>
    """
  end

  defp offers_current(:offers), do: "page"
  defp offers_current(current) when current in [:bid, :write, :details], do: "location"
  defp offers_current(_current), do: nil
end
