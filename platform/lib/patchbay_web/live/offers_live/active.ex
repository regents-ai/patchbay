defmodule PatchbayWeb.OffersLive.Active do
  @moduledoc """
  The signed-in advertiser's active and upcoming placements, with titles,
  duration progress and read-only bid and return figures.

  It reads `Patchbay.Offers.my_active/2`, the read a paired agent's
  `list_my_active_offers` gives (`PatchbayWeb.ForumAPI.MyOffers`), and both
  work out the figures with `PatchbayWeb.OffersLive.Mine`.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.OffersLive.Navigation, only: [offers_header: 1]

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1]

  import PatchbayWeb.OffersLive.Markets,
    only: [credits: 1, slot_label: 1]

  import PatchbayWeb.OffersLive.Mine,
    only: [buyout: 1, unused: 2, upcoming_start: 1, upcoming_end: 1]

  alias Patchbay.Offers

  @impl true
  def mount(_params, _session, socket) do
    as_of = DateTime.utc_now()
    profile = socket.assigns.current_profile

    {:ok,
     assign(socket,
       page_title: "Active Offers",
       as_of: as_of,
       mine: if(profile, do: Offers.my_active(profile, as_of))
     )}
  end

  attr(:starts_at, :any, default: nil)
  attr(:ends_at, :any, default: nil)
  attr(:now, :any, required: true)
  attr(:planned, :boolean, default: false)

  defp duration_timeline(assigns) do
    percent =
      if !assigns.planned && assigns.starts_at && assigns.ends_at do
        duration = max(DateTime.diff(assigns.ends_at, assigns.starts_at, :microsecond), 1)
        elapsed = DateTime.diff(assigns.now, assigns.starts_at, :microsecond)
        elapsed |> Kernel.*(100) |> div(duration) |> max(0) |> min(100)
      else
        0
      end

    assigns = assign(assigns, :percent, percent)

    ~H"""
    <div class="pb-placement-timeline">
      <div class="pb-placement-progress-label">
        <span>{if @planned, do: "Scheduled duration", else: "Duration"}</span>
        <strong>{@percent}% fulfilled</strong>
      </div>
      <progress value={@percent} max="100" aria-label="Placement duration fulfilled">
        {@percent}%
      </progress>
      <div class="pb-placement-dates">
        <span>
          <small>{if @planned, do: "Expected start", else: "Start"}</small>
          <time :if={@starts_at} datetime={DateTime.to_iso8601(@starts_at)}>{moment(@starts_at)}</time>
          <span :if={!@starts_at}>When slot is free</span>
        </span>
        <span>
          <small>{if @planned, do: "Expected end", else: "End"}</small>
          <time :if={@ends_at} datetime={DateTime.to_iso8601(@ends_at)}>{moment(@ends_at)}</time>
          <span :if={!@ends_at}>72 hours later</span>
        </span>
      </div>
    </div>
    """
  end
end
