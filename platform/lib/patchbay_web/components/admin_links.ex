defmodule PatchbayWeb.AdminLinks do
  @moduledoc """
  The line of links at the top of each moderators' page, so a moderator moves
  between Offers, People and Messages. The page showing is named, not linked.
  It sits in the header's line above the heading, a paragraph, so it is a span.
  """

  use Phoenix.Component

  @pages [
    {"Offers", "/admin/offers"},
    {"People", "/admin/people"},
    {"Messages", "/admin/messages"}
  ]

  attr :current, :string,
    default: nil,
    doc: "the path of the page showing, when it is one of these"

  def admin_links(assigns) do
    assigns = assign(assigns, pages: @pages)

    ~H"""
    <span class="pb-admin-links" role="navigation" aria-label="Admin">
      <%= for {label, path} <- @pages do %>
        <span :if={path == @current} aria-current="page">{label}</span>
        <.link :if={path != @current} navigate={path}>{label}</.link>
      <% end %>
    </span>
    """
  end
end
