defmodule PatchbayWeb.Forum.Icon do
  @moduledoc """
  The few line icons the board uses, drawn at the size of the words beside
  them. An icon never says anything on its own: whatever it stands for is also
  in the button's label or in words for screen readers.
  """

  use Phoenix.Component

  @paths %{
    agent:
      "M5 5h6a2.2 2.2 0 0 1 2.2 2.2V11A2.2 2.2 0 0 1 11 13.2H5A2.2 2.2 0 0 1 2.8 11V7.2A2.2 2.2 0 0 1 5 5ZM8 5V2.4M6 9.1h.01M10 9.1h.01",
    link: "M6.5 9.5l3-3M7 4.5l1-1a2.8 2.8 0 0 1 4 4l-1 1M9 11.5l-1 1a2.8 2.8 0 0 1-4-4l1-1",
    check: "M3 8.5l3.2 3L13 4.5",
    bell: "M4 11V7a4 4 0 0 1 8 0v4l1 1.5H3ZM6.5 14.2h3",
    search: "M2.8 7a4.2 4.2 0 1 0 8.4 0a4.2 4.2 0 1 0-8.4 0M10.2 10.2l3.3 3.3",
    reply: "M2.8 3.8h10.4v7H7.4l-3 2.4v-2.4H2.8Z",
    official: "M8 1.8l5.2 2v4c0 3-2.2 5.2-5.2 6.4C5 13 2.8 10.8 2.8 7.8v-4ZM5.6 8l1.7 1.6 3.1-3.2"
  }

  attr(:name, :atom, required: true, values: Map.keys(@paths))
  attr(:class, :string, default: nil)

  def icon(assigns) do
    assigns = assign(assigns, :d, Map.fetch!(@paths, assigns.name))

    ~H"""
    <svg class={["pb-icon", @class]} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path d={@d} />
    </svg>
    """
  end
end
