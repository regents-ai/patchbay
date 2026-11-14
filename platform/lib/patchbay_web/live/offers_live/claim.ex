defmodule PatchbayWeb.OffersLive.Claim do
  @moduledoc """
  What one of the signed-in account's wallets may take back from the market
  on `/offers` (a refund for a lease bought out, or anything else the market
  owes it), and Claim, which sends all of it to that wallet.

  The amount is read from Base at the latest block when the page opens, on
  every press and when a step lands. Claim is disabled only when that read
  says there is nothing to claim. A press sends from the wallet itself, when
  it is the wallet Privy has active (`PatchbayWeb.OnchainSteps`).

  The page passes `profile` (signed in), its `session_lease` as `lease`, and
  the `wallet`. It sends `read: true` when a step has landed.
  """
  use PatchbayWeb, :live_component

  alias Patchbay.Offers
  alias Patchbay.Offers.{Market, Steps}
  alias PatchbayWeb.{CurrentProfile, OnchainSteps}
  alias PatchbayWeb.OffersLive.Words
  alias Regent.Primitives

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> CurrentProfile.check_component_lease(&take_profile/2)
     |> OnchainSteps.init()
     |> assign(claimable: nil, read: :reading)}
  end

  @impl true
  def update(%{read: true}, socket), do: {:ok, read_claimable(socket)}

  def update(assigns, socket) do
    first? = socket.assigns[:wallet] == nil

    socket =
      socket
      |> assign(Map.take(assigns, [:id, :lease, :wallet]))
      |> take_profile(assigns.profile)

    {:ok, if(first?, do: read_claimable(socket), else: socket)}
  end

  defp take_profile(socket, profile), do: assign(socket, profile: profile)

  @impl true
  def handle_event("prepare_and_send", %{"step" => "claim", "address" => address}, socket)
      when is_binary(address) do
    if String.downcase(address) == socket.assigns.wallet do
      prepare_claim(socket)
    else
      {:reply, %{}, failed(socket, %{"step" => "claim", "reason" => "wallet_unavailable"})}
    end
  end

  def handle_event("prepare_and_send", _params, socket), do: {:reply, %{}, socket}

  def handle_event("step_sent", params, socket), do: {:noreply, OnchainSteps.sent(socket, params)}
  def handle_event("step_failed", params, socket), do: {:noreply, failed(socket, params)}

  def handle_event("check_again", %{"hash" => hash}, socket),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result)}

  def handle_async(:claimable, {:ok, {:ok, claimable}}, socket),
    do: {:noreply, assign(socket, claimable: claimable, read: :read)}

  def handle_async(:claimable, _failed, socket), do: {:noreply, assign(socket, read: :failed)}

  # The amount is read again at the press: nothing left means Claim turns
  # disabled with its reason instead of sending.
  defp prepare_claim(socket) do
    wallet = socket.assigns.wallet

    case Market.claimable(wallet) do
      {:ok, 0} ->
        {:reply, %{}, assign(socket, claimable: 0, read: :read)}

      {:ok, claimable} ->
        review =
          RegentChain.Review.new(socket.assigns.id, wallet, Offers.chain(), [Steps.claim(wallet)])

        {:reply, %{review: review, send: "claim"},
         socket |> assign(claimable: claimable, read: :read) |> OnchainSteps.prepared(review)}

      {:error, _unread} ->
        {:reply, %{},
         assign(socket,
           read: :failed,
           press_note: [
             "#{Offers.chain().name} couldn't be read just now, so nothing was sent. Press again."
           ]
         )}
    end
  end

  defp failed(socket, params),
    do: OnchainSteps.failed(socket, params, socket.assigns.wallet, Offers.chain().name)

  # Against the person's wallet-read allowance; past it, the amount already
  # shown stays.
  defp read_claimable(socket) do
    %{wallet: wallet, profile: profile} = socket.assigns

    start_async(socket, :claimable, fn ->
      case Patchbay.Limits.spend(:wallet_read, {:profile, profile.id}) do
        :ok -> Market.claimable(wallet)
        :limited -> {:error, :limited}
      end
    end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        sent:
          assigns.presses
          |> RegentChain.Presses.shown()
          |> Enum.map(&OnchainSteps.describe(&1, Offers.chain().name))
      )

    ~H"""
    <li id={@id} class="pb-claim" phx-hook="OnchainSteps">
      <div class="pb-claim-row">
        <Primitives.address id={"#{@id}-wallet"} address={@wallet} variant="compact" />
        <Primitives.figure
          class="pb-claim-amount"
          value={claimable(@claimable, @read)}
        />
        <div class="pb-step">
          <button
            type="button"
            class="rg-button rg-button--secondary pb-step-button"
            data-onchain-step="claim"
            disabled={@claimable == 0}
            aria-describedby={@claimable == 0 && "#{@id}-why"}
          >
            <span class="rg-button__label">Claim</span>
          </button>
          <p :if={@claimable == 0} id={"#{@id}-why"} class="pb-step-why">Nothing to claim</p>
        </div>
      </div>

      <p class="pb-press-note" aria-live="polite" hidden={!@press_note}>
        <OnchainSteps.note :if={@press_note} id={"#{@id}-note"} parts={@press_note} />
      </p>
      <p class="pb-press-note" data-onchain-lost hidden>
        This page lost its connection, so nothing was sent. Press again once it's back.
      </p>
      <p class="pb-press-note" data-onchain-unreported hidden>
        Your wallet answered, but this page lost its connection. Check your wallet activity.
      </p>

      <ol :if={@sent != []} class="pb-sent" aria-label="Sent">
        <li :for={entry <- @sent} class="pb-sent-row" data-state={entry.state}>
          <span class="pb-sent-name">Claim</span>
          <span class="pb-sent-words">{entry.words}</span>
          <Primitives.address id={"#{@id}-tx-#{entry.hash}"} address={entry.hash} kind="tx" />
          <button
            :if={entry.state == :stalled}
            type="button"
            class="rg-button rg-button--quiet"
            phx-click="check_again"
            phx-value-hash={entry.hash}
            phx-target={@myself}
          >
            <span class="rg-button__label">Check again</span>
          </button>
        </li>
      </ol>
    </li>
    """
  end

  defp claimable(nil, :failed), do: "Couldn't be read"
  defp claimable(nil, _reading), do: "—"
  defp claimable(units, _read), do: "#{Words.usdc(units)} USDC"
end
