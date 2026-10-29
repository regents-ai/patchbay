defmodule PatchbayWeb.OffersLive.Navigation do
  @moduledoc """
  The persistent page navigation for the Agent Offers route group. Slots and
  the Guide are for everyone; Your Offers, Active and History are a signed-in
  person's own, so only they see those tabs.
  """
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  attr(:current, :atom, required: true)
  attr(:signed_in, :boolean, required: true)

  def offers_header(assigns) do
    ~H"""
    <.board_header>
      <:title>Agent Offers</:title>
      <:crumbs><.link navigate={~p"/"}>PATCHBAY</.link> / OFFERS</:crumbs>
    </.board_header>
    <nav class="pb-offers-nav" aria-label="Agent Offers pages">
      <.link navigate={~p"/offers"} aria-current={slots_current(@current)}>Slots</.link>
      <%= if @signed_in do %>
        <.link navigate={~p"/offers/create"} aria-current={@current == :write && "page"}>Your Offers</.link>
        <.link navigate={~p"/offers/active"} aria-current={@current == :active && "page"}>Active</.link>
        <.link navigate={~p"/offers/history"} aria-current={@current == :history && "page"}>History</.link>
      <% end %>
      <.link navigate={~p"/offers/how-it-works"} aria-current={@current == :details && "page"}>Guide</.link>
    </nav>
    """
  end

  # A bid page is reached from a slot, so it sits under the Slots tab.
  defp slots_current(:offers), do: "page"
  defp slots_current(:bid), do: "location"
  defp slots_current(_current), do: nil
end
