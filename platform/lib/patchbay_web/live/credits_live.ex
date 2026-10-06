defmodule PatchbayWeb.CreditsLive do
  @moduledoc """
  The Credits balance in the header of every page, for a profile signed in
  with Privy, and the Buy Credits dialog it opens. It stays put while a person
  moves between live pages, and the balance changes the moment Credits move,
  whichever Regent site moved them.

  The panel (`PatchbayWeb.CreditsPanel`) is drawn only once the dialog has
  been opened, so a page that never opens it never reads a wallet. Any page
  opens it with `JS.dispatch("pb:credits-open", to: "#pb-credits")`.
  """

  use PatchbayWeb, :live_view

  alias RegentCredits.Amount

  on_mount {PatchbayWeb.CurrentProfile, :default}

  @impl true
  def mount(_params, _session, socket) do
    %{privy_user_id: did} = socket.assigns.current_profile

    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(did))

    {:ok, socket |> assign(opened: false) |> read()}
  end

  @impl true
  def handle_info(:credits_changed, socket), do: {:noreply, read(socket)}

  @impl true
  def handle_event("opened", _params, socket), do: {:noreply, assign(socket, opened: true)}

  defp read(socket),
    do:
      assign(socket, balance: RegentCredits.balance(socket.assigns.current_profile.privy_user_id))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pb-credits">
      <button
        type="button"
        class="pb-credits-balance"
        phx-click={JS.dispatch("pb:credits-open", to: "#pb-credits")}
        aria-haspopup="dialog"
      >
        {Amount.format(@balance.available)}
      </button>
      <dialog
        id="pb-credits"
        class="pb-credits-dialog"
        phx-hook="PatchbayCreditsDialog"
        phx-mounted={JS.ignore_attributes("open")}
        aria-label="Buy Credits"
      >
        <form method="dialog" class="pb-credits-close">
          <button type="submit" aria-label="Close">Close</button>
        </form>
        <.live_component
          :if={@opened}
          module={PatchbayWeb.CreditsPanel}
          id="pb-credits-panel"
          profile={@current_profile}
          balance={@balance}
        />
      </dialog>
    </div>
    """
  end
end
