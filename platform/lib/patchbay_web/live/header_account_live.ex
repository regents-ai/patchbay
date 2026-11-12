defmodule PatchbayWeb.HeaderAccountLive do
  @moduledoc """
  The signed-in person's part of the header on every page, as in the Regent
  template: the account menu (`Regent.Account.menu`) their picture and name at
  the top right open. The menu shows their picture, name and wallet, their
  three most recently active agents (`PatchbayWeb.MenuAgents`), Pair New Agent,
  the theme switch (`PatchbayWeb.ThemeSwitch`), Manage Account and Sign out. Pair New Agent opens the pairing window
  (`#pb-pairing`, with `PatchbayWeb.PairingBox`) over the page; the agents are
  on the Agents page, and everything else about the account on the Account page
  (`PatchbayWeb.AccountLive`).

  It stays put while a person moves between live pages. The agents change the
  moment one pairs, checks in or is unpaired, whichever Regent site it happened
  on.

  The open address (`PatchbayWeb.SiteEdition`) shows no wallet: the menu keeps
  the name, the agents, Pair New Agent, the theme switch, Manage Account and
  Sign out.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Identity.AgentProfile

  # When the sign-in runs out on an open page, the menu drops away and the page
  # around it stays where it is, with anything half written in it.
  on_mount {PatchbayWeb.CurrentProfile, :account}

  @impl true
  def mount(_params, _session, %{assigns: %{current_profile: nil}} = socket),
    do: {:ok, socket}

  def mount(_params, _session, socket) do
    %{privy_user_id: did} = socket.assigns.current_profile

    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))

    {:ok, socket}
  end

  @impl true
  def handle_info(_changed, %{assigns: %{current_profile: nil}} = socket),
    do: {:noreply, socket}

  # An agent paired, checked in or was unpaired, here or on another Regent site.
  # The account menu's agents and the pairing window are on every page.
  def handle_info(:agents_changed, socket) do
    send_update(PatchbayWeb.MenuAgents, id: "account-menu-agents", agents_changed: true)
    send_update(PatchbayWeb.PairingBox, id: "pb-pairing-box", agents_changed: true)
    {:noreply, socket}
  end

  @impl true
  def render(%{current_profile: nil} = assigns) do
    ~H"""
    <div class="pb-account-header"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="pb-account-header">
      <Regent.Structure.dialog
        id="pb-pairing"
        class="pb-pairing-dialog"
        aria-labelledby="pb-pairing-title"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <form method="dialog" class="pb-dialog-close">
          <button type="submit" aria-label="Close"><Regent.Icons.icon name="x" /></button>
        </form>
        <h2 id="pb-pairing-title">Pair New Agent</h2>
        <.live_component
          module={PatchbayWeb.PairingBox}
          id="pb-pairing-box"
          lease={@session_lease}
          profile={@current_profile}
          site_edition={@site_edition}
        />
      </Regent.Structure.dialog>

      <Regent.Account.menu
        id="account-menu"
        name={AgentProfile.name_for(@current_profile, :human)}
        wallet={if @site_edition == :main, do: @current_profile.wallet_address}
        ens_name={if @site_edition == :main, do: @current_profile.ens_name}
        manage_href={~p"/account"}
        pair_window="pb-pairing"
      >
        <:picture>
          <PatchbayWeb.Forum.Nameplate.author_avatar author={@current_profile} kind={:human} />
        </:picture>
        <:agents>
          <.live_component
            module={PatchbayWeb.MenuAgents}
            id="account-menu-agents"
            lease={@session_lease}
            profile={@current_profile}
          />
        </:agents>
        <:theme>
          <span aria-hidden="true">Light theme</span>
          <PatchbayWeb.ThemeSwitch.theme_toggle id="account-menu-theme" />
        </:theme>
      </Regent.Account.menu>
    </div>
    """
  end
end
