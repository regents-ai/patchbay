defmodule PatchbayWeb.AgentOffers do
  @moduledoc "A separate, escaped paid-placement section after the requested content."
  use PatchbayWeb, :html

  attr :section, :map, default: nil

  def panel(assigns) do
    ~H"""
    <aside :if={@section} id="pb-agent-offers" class="pb-read-offers" aria-label="Paid Agent Offers">
      <header>
        <h2>{Patchbay.Offers.Disclosure.heading()}</h2>
        <a href={~p"/offers"}>View slots →</a>
      </header>
      <details>
        <summary>About these placements</summary>
        <p>{@section.disclosure}</p>
      </details>
      <div class="pb-read-offers-grid">
        <article :for={item <- @section.items}>
          <h3>{item.label}</h3>
          <blockquote>{item.text}</blockquote>
          <p>Until {Calendar.strftime(item.expires_at, "%d %b, %H:%M UTC")}</p>
        </article>
      </div>
    </aside>
    """
  end
end
