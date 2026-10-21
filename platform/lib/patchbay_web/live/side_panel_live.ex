defmodule PatchbayWeb.SidePanelLive do
  @moduledoc """
  The side panel on every page for a signed-in person, as in the Regent
  template, opened by their name in the header: Sign out and Manage Account
  (this site's Account page), then the agents paired with the account
  (`PatchbayWeb.PanelAgents`), headed by a link to them on the Account page, with where
  each was last active, and Pair New Agent
  (`PatchbayWeb.PairingBox`). The root layout renders it in the header, beside
  the page's own view. Whether it is open is the browser's (`assets/js/hooks/side_panel.ts` and
  the `patchbay_aside` cookie, read into `<html data-aside>` by
  `PatchbayWeb.Plugs.Panels`), so the server never stores it.
  """
  use PatchbayWeb, :live_view

  on_mount {PatchbayWeb.CurrentProfile, :default}

  @impl true
  def mount(_params, _session, socket) do
    %{privy_user_id: did} = socket.assigns.current_profile

    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))

    {:ok, socket}
  end

  # An agent paired, checked in or was unpaired, here or on another Regent site.
  @impl true
  def handle_info(:agents_changed, socket) do
    send_update(PatchbayWeb.PanelAgents, id: "shell-agents", agents_changed: true)
    send_update(PatchbayWeb.PairingBox, id: "shell-pairing-box", agents_changed: true)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="shell-aside"
      phx-hook="SidePanel"
      aria-label="Your account and agents"
      tabindex="-1"
    >
      <div class="shell-aside__head">
        <Regent.Primitives.button variant="secondary" type="button" data-pb-account="sign-out">
          Sign out
        </Regent.Primitives.button>
        <a href={~p"/account"} class="rg-button rg-button--secondary">
          Manage Account
        </a>
      </div>

      <.live_component
        module={PatchbayWeb.PanelAgents}
        id="shell-agents"
        lease={@session_lease}
        profile={@current_profile}
      />

      <section id="shell-pairing" aria-labelledby="shell-pairing-title">
        <h2 id="shell-pairing-title">Pair New Agent</h2>
        <.live_component
          module={PatchbayWeb.PairingBox}
          id="shell-pairing-box"
          lease={@session_lease}
          profile={@current_profile}
        />
      </section>
    </aside>
    """
  end
end
