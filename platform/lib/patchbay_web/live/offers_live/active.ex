defmodule PatchbayWeb.OffersLive.Active do
  @moduledoc """
  The signed-in advertiser's active and upcoming placements, with titles,
  duration progress and read-only bid and return figures. An open tab reads
  them again whenever a slot moves on or the advertiser's Credits move.

  It reads `Patchbay.Offers.my_active/1`, the read a paired agent's
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
  alias Patchbay.Offers.Slot

  @impl true
  def mount(_params, _session, socket) do
    profile = socket.assigns.current_profile

    if connected?(socket) and profile do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Slot.topic())
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(profile.privy_user_id))
    end

    {:ok, socket |> assign(page_title: "Active Offers") |> read()}
  end

  # A slot that moved on, or the advertiser's Credits moving (a new bid held,
  # or one given back), changes what this tab shows.
  @impl true
  def handle_info(:offer_markets_changed, socket), do: {:noreply, read(socket)}
  def handle_info(:credits_changed, socket), do: {:noreply, read(socket)}

  defp read(socket) do
    as_of = DateTime.utc_now()
    profile = socket.assigns.current_profile
    assign(socket, as_of: as_of, mine: if(profile, do: Offers.my_active(profile)))
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
