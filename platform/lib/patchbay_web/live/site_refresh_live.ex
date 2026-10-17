defmodule PatchbayWeb.SiteRefreshLive do
  @moduledoc """
  A site's picture on its page, with "Refresh this site": any visitor may ask
  for a new picture of the site and a new check of its WebMCP tools, once
  the last picture is a day old (`PatchbayWeb.Forum.SiteChecks.refresh/3`).
  The button stays in view when it can't be pressed, with when it can be
  again. The picture and the words change when the new picture, or the
  check, comes back.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1, site_domain: 1, site_screenshot_url: 1]

  alias Patchbay.Forum
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.SiteCheck
  alias PatchbayWeb.Forum.SiteChecks

  @impl true
  def mount(_params, %{"origin" => origin, "visitor" => visitor}, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, "site_check:" <> origin)
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, "site_picture:" <> origin)
    end

    {:ok,
     socket
     |> assign(origin: origin, visitor: visitor, limited?: false)
     |> assign_state(read_site(origin), SiteChecks.current(origin))}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{resource: SiteCheck, data: check}, socket),
    do: {:noreply, assign_state(socket, read_site(socket.assigns.origin), check)}

  def handle_info(%Ash.Notifier.Notification{resource: Site}, socket),
    do: {:noreply, assign_state(socket, read_site(socket.assigns.origin), socket.assigns.check)}

  # Whether the site may be refreshed is read again here, never taken from
  # the page.
  @impl true
  def handle_event("refresh", _params, socket) do
    %{origin: origin, visitor: visitor} = socket.assigns
    site = read_site(origin)
    {answer, check} = SiteChecks.refresh(site, SiteChecks.current(origin), visitor)

    {:noreply, socket |> assign(limited?: answer == :limited) |> assign_state(site, check)}
  end

  defp read_site(origin), do: Forum.get_site_by_origin!(origin, load: [:refresh_due?])

  defp assign_state(socket, site, check) do
    assign(socket,
      site: site,
      check: check,
      state: SiteChecks.refresh_state(site, check),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <figure :if={url = site_screenshot_url(@site)} class="pb-entry-shot">
      <img
        src={url}
        alt={"Screenshot of " <> site_domain(@site)}
        width="1600"
        height="1000"
        loading="lazy"
        decoding="async"
      />
    </figure>
    <p class="pb-site-refresh">
      <button
        type="button"
        class="pb-quiet-button"
        phx-click="refresh"
        disabled={@state != :ready}
      >
        Refresh this site
      </button>
      <span role="status">
        <.refresh_words state={@state} site={@site} now={@now} />
      </span>
    </p>
    <p :if={@limited?} class="pb-site-refresh-note" role="alert">
      You've refreshed a lot of sites just now. Try again in a few minutes.
    </p>
    """
  end

  attr(:state, :any, required: true)
  attr(:site, :map, required: true)
  attr(:now, DateTime, required: true)

  defp refresh_words(%{state: :refreshing} = assigns),
    do: ~H"Taking a new picture and checking its tools…"

  defp refresh_words(%{state: {:fresh, at}} = assigns) do
    assigns = assign(assigns, at: at, again: again_words(at, assigns.now))

    ~H"""
    Refreshed <.ago at={@at} now={@now} /> · again {@again}
    """
  end

  defp refresh_words(
         %{state: :ready, site: %{screenshot_captured_at: %DateTime{} = at}} = assigns
       ) do
    assigns = assign(assigns, at: at)
    ~H"Picture taken <.ago at={@at} now={@now} />"
  end

  defp refresh_words(assigns), do: ~H""

  # How long until the site can be refreshed again, rounded up, so the two
  # times add up to a day: "in 21 hours", "in 5 minutes".
  defp again_words(at, now) do
    seconds = max(DateTime.diff(DateTime.shift(at, day: 1), now), 1)

    if seconds >= 3600,
      do: in_words(div(seconds + 3599, 3600), "hour"),
      else: in_words(div(seconds + 59, 60), "minute")
  end

  defp in_words(1, word), do: "in 1 " <> word
  defp in_words(count, word), do: "in #{count} #{word}s"

  attr(:at, DateTime, required: true)
  attr(:now, DateTime, required: true)

  defp ago(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={moment(@at)}>{RegentFormat.relative_time(
      @at,
      @now
    )}</time>
    """
  end
end
