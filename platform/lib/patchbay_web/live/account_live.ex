defmodule PatchbayWeb.AccountLive do
  @moduledoc """
  The signed-in person's Account page, as in the Regent template: who
  Patchbay knows them as, their Profile on every Regent site, the agents they
  paired, their Credits and this browser's session.

  Everything here is read from the sign-in the page already holds; nothing on
  it asks the visitor to sign in again. When the sign-in ends while the page is
  open, the page stays and says so (`PatchbayWeb.CurrentProfile`, `:account`).
  The Credits figures and the agents list change the moment either changes on
  any Regent site.
  """

  use PatchbayWeb, :live_view

  alias PatchbayWeb.Read

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Account", credits: %Read{})

    case socket.assigns.current_profile do
      nil ->
        {:ok, socket}

      %{privy_user_id: did} ->
        if connected?(socket) do
          :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(did))
          :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))
        end

        {:ok, read_credits(socket)}
    end
  end

  @impl true
  def handle_info(:credits_changed, socket), do: {:noreply, read_credits(socket)}

  def handle_info(:agents_changed, socket) do
    send_update(PatchbayWeb.AgentsPanel, id: "account-agents", agents_changed: true)
    {:noreply, socket}
  end

  @impl true
  def handle_async({Read, :credits, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp read_credits(socket) do
    did = socket.assigns.current_profile.privy_user_id
    Read.start(socket, :credits, did, fn -> {:ok, RegentCredits.balance(did)} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="account-page" class="patchbay-shell pb-account-page">
      <header class="pb-account-heading">
        <h1 tabindex="-1">Account</h1>
        <p>Who Patchbay knows you as, and your session on this browser.</p>
      </header>

      <Regent.Account.signed_out
        :if={is_nil(@current_profile)}
        id="account-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button variant="primary" type="button" data-pb-account="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>

      <div
        :if={@current_profile}
        id="account-sections"
        class="pb-account-grid"
        phx-hook="MotionCascade"
        data-variant={PatchbayWeb.Motion.standard("grid")}
      >
        <Regent.HolographicCard.card
          id="account-identity"
          class="pb-account-identity"
          phx-hook="HolographicCard"
          data-holo-crown="false"
        >
          <p class="pb-account-kicker">Your account</p>
          <h2>{@current_profile.human_name}</h2>
          <p :if={@current_profile.wallet_address}>
            <code>{RegentFormat.short_address(@current_profile.wallet_address)}</code>
          </p>
        </Regent.HolographicCard.card>

        <%!-- Filled in by the Privy bridge once the page is in the browser. --%>
        <div id="account-profile" class="pb-account-panel" phx-update="ignore">
          <Regent.Profile.panel signed_in />
        </div>

        <.live_component
          module={PatchbayWeb.AgentsPanel}
          id="account-agents"
          profile={@current_profile}
          lease={@session_lease}
        />

        <Regent.Account.credits_summary
          id="account-credits"
          available={@credits.value && RegentCredits.Amount.format(@credits.value.available)}
          held={@credits.value && RegentCredits.Amount.format(@credits.value.held)}
          state={if @credits.state in [:idle, :empty], do: :loading, else: @credits.state}
        >
          <p class="pb-account-credits">
            <a href="https://regents.sh/account">Manage Credits on regents.sh</a>
            <a href={~p"/points"}>Your Points</a>
          </p>
        </Regent.Account.credits_summary>

        <section class="pb-account-panel" aria-labelledby="account-session-title">
          <h2 id="account-session-title">
            Session
            <Regent.Primitives.tip id="account-session-tip" label="About signing out">
              Signing out ends the session on this browser only.
            </Regent.Primitives.tip>
          </h2>
          <Regent.Primitives.button type="button" variant="secondary" data-pb-account="sign-out">
            Sign out
          </Regent.Primitives.button>
        </section>
      </div>
    </main>
    """
  end
end
