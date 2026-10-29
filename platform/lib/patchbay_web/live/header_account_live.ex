defmodule PatchbayWeb.HeaderAccountLive do
  @moduledoc """
  The signed-in person's part of the header on every page, as in the Regent
  template: their Credits balance with the Buy Credits dialog it opens, and the
  account menu (`Regent.Account.menu`) their picture and name at the top right
  open. The menu shows their picture, name and wallet, their three most recently
  active agents (`PatchbayWeb.MenuAgents`), Pair New Agent, Manage Account and
  Sign out. Pairing itself and everything else about the account are on the
  Account page (`PatchbayWeb.AccountLive`).

  It stays put while a person moves between live pages. The balance changes the
  moment Credits move, and the agents the moment one pairs, checks in or is
  unpaired, whichever Regent site it happened on. Only a balance just read shows;
  while it is read again, or when it can't be, the figure is a dash. Narrower than
  22.5rem the header leaves the balance out and the menu shows it instead, opening
  the same dialog.

  The Buy Credits panel (`PatchbayWeb.CreditsPanel`) is drawn only once the
  dialog has been opened, so a page that never opens it never reads a wallet. Any
  page opens it with `JS.dispatch("pb:credits-open", to: "#pb-credits")`, or with
  a `data-credits-open` button (`assets/js/account_menu.ts`).

  The open address (`PatchbayWeb.SiteEdition`) shows no Credits and no wallet:
  the menu keeps the name, the agents, Pair New Agent, Manage Account and Sign
  out.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Read
  alias RegentCredits.Amount

  # When the sign-in runs out on an open page, the balance and the menu drop away
  # and the page around them stays where it is, with anything half written in it.
  on_mount {PatchbayWeb.CurrentProfile, :account}

  @impl true
  def mount(_params, _session, %{assigns: %{current_profile: nil}} = socket),
    do: {:ok, assign(socket, opened: false, credits: %Read{})}

  def mount(_params, _session, %{assigns: %{site_edition: :open}} = socket) do
    %{privy_user_id: did} = socket.assigns.current_profile

    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))

    {:ok, assign(socket, opened: false, credits: %Read{})}
  end

  def mount(_params, _session, socket) do
    %{privy_user_id: did} = socket.assigns.current_profile

    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(did))
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))
    end

    {:ok, socket |> assign(opened: false, credits: %Read{}) |> read()}
  end

  @impl true
  def handle_info(_changed, %{assigns: %{current_profile: nil}} = socket),
    do: {:noreply, socket}

  def handle_info(:credits_changed, socket), do: {:noreply, read(socket)}

  # An agent paired, checked in or was unpaired, here or on another Regent site.
  def handle_info(:agents_changed, socket) do
    send_update(PatchbayWeb.MenuAgents, id: "account-menu-agents", agents_changed: true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("opened", _params, socket), do: {:noreply, assign(socket, opened: true)}

  @impl true
  def handle_async({Read, :credits, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp read(socket) do
    did = socket.assigns.current_profile.privy_user_id
    Read.start(socket, :credits, did, fn -> {:ok, RegentCredits.balance(did)} end)
  end

  @impl true
  def render(%{current_profile: nil} = assigns) do
    ~H"""
    <div class="pb-credits"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="pb-credits">
      <button
        :if={@site_edition == :main}
        id="pb-credits-balance"
        type="button"
        class="pb-credits-balance"
        phx-click={JS.dispatch("pb:credits-open", to: "#pb-credits")}
        phx-hook="MotionCount"
        data-variant="flash"
        aria-haspopup="dialog"
        aria-controls="pb-credits"
        aria-label={label(@credits)}
      >
        <.amount credits={@credits} />
      </button>
      <Regent.Structure.dialog
        :if={@site_edition == :main}
        id="pb-credits"
        class="pb-credits-dialog"
        phx-hook="PatchbayCreditsDialog"
        phx-mounted={JS.ignore_attributes("open")}
        aria-label="Buy Credits"
      >
        <form method="dialog" class="pb-credits-close">
          <button type="submit" aria-label="Close">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
          </button>
        </form>
        <.live_component
          :if={@opened}
          module={PatchbayWeb.CreditsPanel}
          id="pb-credits-panel"
          profile={@current_profile}
          lease={@session_lease}
          credits={@credits}
        />
      </Regent.Structure.dialog>

      <Regent.Account.menu
        id="account-menu"
        name={AgentProfile.name_for(@current_profile, :human)}
        wallet={if @site_edition == :main, do: @current_profile.wallet_address}
        ens_name={if @site_edition == :main, do: @current_profile.ens_name}
        manage_href={~p"/account"}
        pair_href={~p"/account#account-pairing"}
      >
        <:picture>
          <PatchbayWeb.Forum.Nameplate.author_avatar author={@current_profile} kind={:human} />
        </:picture>
        <:balance :if={@site_edition == :main}>
          <button
            type="button"
            id="account-menu-credits"
            aria-haspopup="dialog"
            aria-controls="pb-credits"
            aria-label={label(@credits)}
            data-credits-open
          >
            <.amount credits={@credits} />
          </button>
        </:balance>
        <:agents>
          <.live_component
            module={PatchbayWeb.MenuAgents}
            id="account-menu-agents"
            lease={@session_lease}
            profile={@current_profile}
          />
        </:agents>
      </Regent.Account.menu>
    </div>
    """
  end

  defp label(%{state: :ready, value: balance}), do: Amount.format(balance.available)
  defp label(%{state: state}) when state in [:error, :stale], do: "Credits unavailable"
  defp label(_credits), do: "Credits loading"

  attr :credits, Read, required: true

  # "12.40 Credits", whose unit a phone's header leaves out for room.
  defp amount(%{credits: %{state: :ready, value: balance}} = assigns) do
    [number, unit] = String.split(Amount.format(balance.available), " ", parts: 2)
    assigns = assign(assigns, number: number, unit: unit)

    ~H"""
    <span data-count>{@number}</span> <span class="pb-credits-unit">{@unit}</span>
    """
  end

  defp amount(assigns) do
    ~H"""
    <span data-count>—</span> <span class="pb-credits-unit">Credits</span>
    """
  end
end
