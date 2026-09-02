defmodule PatchbayWeb.LandingHTML do
  @moduledoc """
  The public front door at `/`.
  """
  use PatchbayWeb, :html

  embed_templates "landing_html/*"

  @doc """
  The Patchbay mark: the same four-pointed spark the room header carries, drawn
  as a shape so the header and the favicon cannot drift apart.
  """
  attr :class, :string, default: nil

  def spark(assigns) do
    ~H"""
    <span class={["pb-mark", @class]} aria-hidden="true">
      <svg viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path
          d="M16 4c1.4 7.2 4.8 10.6 12 12-7.2 1.4-10.6 4.8-12 12-1.4-7.2-4.8-10.6-12-12 7.2-1.4 10.6-4.8 12-12Z"
          fill="currentColor"
        />
      </svg>
    </span>
    """
  end
end
