defmodule PatchbayWeb.OffersLive.Buy do
  @moduledoc """
  Buying one slot of a placement on `/offers`, or buying it out: the person
  picks one of their campaigns and an amount, lets the market take that much
  USDC (Approve), then buys (Buy, or Buy out when the slot has a lease).

  Each press asks for its steps (`PatchbayWeb.OnchainSteps`), built here for
  the form on screen: an approval of exactly the amount, or the purchase with
  Patchbay's admission (`Patchbay.Offers.Admission`), signed for that press.
  Both pay from the campaign's own wallet. The figures beside the buttons are
  read from Base at the latest block when the panel opens, on every change
  and on every press, and again when a step lands. Buy is disabled only when
  they make it certain to fail: the placement has closed, the amount is below
  the slot's minimum, the wallet holds too little USDC, or its approval is
  not on the chain yet. A campaign Patchbay will not admit there shows why in
  place of the buttons.

  The page passes `profile` (signed in), its `session_lease` as `lease`, the
  `placement` and its board `slot`, and the person's `campaigns`. It sends
  `read: true` when a step has landed.
  """
  use PatchbayWeb, :live_component

  alias Patchbay.Offers
  alias Patchbay.Offers.{Admission, Market, Steps}
  alias PatchbayWeb.{CurrentProfile, OnchainSteps}
  alias PatchbayWeb.OffersLive.Words
  alias Regent.Primitives

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> CurrentProfile.check_component_lease(&take_profile/2)
     |> OnchainSteps.init()
     |> assign(figures: nil, figures_read: :reading, campaign: nil, amount: "", refusal: nil)}
  end

  @impl true
  def update(%{read: true}, socket), do: {:ok, read_figures(socket)}

  def update(assigns, socket) do
    moved? =
      socket.assigns[:placement] == nil or
        {socket.assigns.placement.placement_id, socket.assigns.slot.slot} !=
          {assigns.placement.placement_id, assigns.slot.slot}

    socket =
      socket
      |> assign(Map.take(assigns, [:id, :lease, :placement, :slot, :campaigns]))
      |> take_profile(assigns.profile)

    if moved? do
      {:ok,
       socket
       |> choose(campaign_id(socket.assigns.campaigns), Words.usdc(assigns.slot.minimum_usdc))
       |> read_figures()}
    else
      {:ok,
       choose(
         socket,
         socket.assigns.campaign && socket.assigns.campaign.id,
         socket.assigns.amount
       )}
    end
  end

  # The profile as the page gave it, or as it reads now before each event
  # (`CurrentProfile.check_component_lease/2`).
  defp take_profile(socket, profile), do: assign(socket, profile: profile)

  @impl true
  def handle_event("change", params, socket) do
    wallet = socket.assigns.campaign && socket.assigns.campaign.advertiser
    socket = choose(socket, params["campaign"], params["amount"] || "")
    now = socket.assigns.campaign && socket.assigns.campaign.advertiser
    {:noreply, if(now != wallet, do: read_figures(socket), else: socket)}
  end

  def handle_event(
        "prepare_and_send",
        %{"step" => name, "form" => form, "address" => address},
        socket
      )
      when is_binary(address) do
    socket = choose(socket, form["campaign"], form["amount"] || "")

    case prepare(socket, name, String.downcase(address)) do
      {:ok, review, socket} ->
        {:reply, %{review: review, send: name}, OnchainSteps.prepared(socket, review)}

      {:none, socket} ->
        {:reply, %{}, socket}
    end
  end

  def handle_event("step_sent", params, socket), do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    socket = choose(socket, params["form"]["campaign"], params["form"]["amount"] || "")
    {:noreply, OnchainSteps.failed(socket, params, wallet(socket), Offers.chain().name)}
  end

  def handle_event("check_again", %{"hash" => hash}, socket),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result)}

  def handle_async(:figures, {:ok, {:ok, figures}}, socket),
    do: {:noreply, assign(socket, figures: figures, figures_read: :read)}

  def handle_async(:figures, _failed, socket),
    do: {:noreply, assign(socket, figures_read: :failed)}

  # The campaign and amount on screen, and whether Patchbay would admit the
  # purchase. An unknown campaign id is no campaign.
  defp choose(socket, campaign_id, amount) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1.id == campaign_id))

    refusal =
      with %{} <- campaign,
           {:error, reason} <-
             Admission.check(
               socket.assigns.profile,
               campaign,
               socket.assigns.placement.placement_id,
               socket.assigns.slot.slot
             ) do
        Words.refusal(reason, campaign, socket.assigns.placement)
      else
        _admitted -> nil
      end

    assign(socket, campaign: campaign, amount: amount, refusal: refusal)
  end

  defp campaign_id([first | _]), do: first.id
  defp campaign_id([]), do: nil

  defp wallet(%{assigns: %{campaign: %{advertiser: advertiser}}}), do: advertiser
  defp wallet(_socket), do: nil

  defp units(%{assigns: %{amount: amount}}) do
    case Words.parse_usdc(amount) do
      {:ok, units} -> units
      :error -> nil
    end
  end

  # The steps for one press, from the campaign's own wallet when that is the
  # wallet Privy has active.
  defp prepare(socket, name, address) do
    with {:ok, campaign, units} <- ready(socket),
         :ok <- same_wallet(socket, campaign, address) do
      step(socket, name, campaign, units)
    end
  end

  defp ready(socket) do
    case {socket.assigns.campaign, units(socket), socket.assigns.refusal} do
      {nil, _units, _refusal} ->
        {:none, nothing(socket, "Choose a campaign, then press again.")}

      {_campaign, nil, _refusal} ->
        {:none, nothing(socket, "Enter an amount in USDC, then press again.")}

      {_campaign, _units, [_ | _]} ->
        {:none, socket}

      {campaign, units, nil} ->
        {:ok, campaign, units}
    end
  end

  defp same_wallet(socket, %{advertiser: advertiser}, address) do
    if address == advertiser,
      do: :ok,
      else:
        {:none,
         OnchainSteps.failed(
           socket,
           %{"step" => "buy", "reason" => "wallet_unavailable"},
           advertiser,
           Offers.chain().name
         )}
  end

  defp step(socket, "approve", campaign, units),
    do: {:ok, review(socket, campaign, Steps.approve(units)), socket}

  # The purchase is built from the chain as it reads now: the slot's lease
  # nonce, and the figures that make it certain to fail.
  defp step(socket, "buy", campaign, units) do
    case figures(
           socket.assigns.placement.placement_id,
           socket.assigns.slot.slot,
           campaign.advertiser
         ) do
      {:ok, figures} ->
        socket = assign(socket, figures: figures, figures_read: :read)

        with nil <- blocked(figures, units),
             {:ok, admission} <-
               Admission.admit(
                 socket.assigns.profile,
                 campaign,
                 socket.assigns.placement.placement_id,
                 socket.assigns.slot.slot,
                 units,
                 figures.nonce
               ) do
          {:ok, review(socket, campaign, Steps.buy(admission)), socket}
        else
          {:error, reason} ->
            {:none,
             assign(socket, refusal: Words.refusal(reason, campaign, socket.assigns.placement))}

          _blocked ->
            {:none, socket}
        end

      {:error, _unread} ->
        {:none,
         nothing(
           assign(socket, figures_read: :failed),
           "#{Offers.chain().name} couldn't be read just now, so nothing was sent. Press again."
         )}
    end
  end

  defp step(socket, _unknown, _campaign, _units), do: {:none, socket}

  defp nothing(socket, words), do: assign(socket, press_note: [words])

  defp review(socket, campaign, step) do
    RegentChain.Review.new(socket.assigns.id, campaign.advertiser, Offers.chain(), [step], %{
      "campaign" => campaign.id,
      "amount" => socket.assigns.amount
    })
  end

  # Read once per open, change of wallet and landed step, against the
  # person's wallet-read allowance; past it, the figures already shown stay.
  defp read_figures(%{assigns: %{campaign: nil}} = socket), do: assign(socket, figures: nil)

  defp read_figures(socket) do
    %{placement: placement, slot: slot, campaign: campaign, profile: profile} = socket.assigns

    start_async(socket, :figures, fn ->
      case Patchbay.Limits.spend(:wallet_read, {:profile, profile.id}) do
        :ok -> figures(placement.placement_id, slot.slot, campaign.advertiser)
        :limited -> {:error, :limited}
      end
    end)
  end

  defp figures(placement_id, slot, wallet) do
    with {:ok, minimum} <- Market.minimum_price(placement_id, slot),
         {:ok, lease} <- Market.lease(placement_id, slot),
         {:ok, terminated_at} <- Market.terminated_at(placement_id),
         {:ok, allowance} <- Market.allowance(wallet),
         {:ok, balance} <- Market.balance(wallet) do
      {:ok,
       %{
         wallet: wallet,
         minimum: minimum,
         nonce: lease.nonce,
         closed?: terminated_at != nil,
         allowance: allowance,
         balance: balance
       }}
    end
  end

  # Why Buy is certain to fail, from the chain at the latest block, or nil.
  # Figures not read yet, or read for another wallet, never block a press.
  defp blocked(%{closed?: true}, _units), do: "Placement closed"
  defp blocked(%{minimum: minimum}, units) when units < minimum, do: "Below the minimum"
  defp blocked(%{balance: balance}, units) when balance < units, do: "Not enough USDC"
  defp blocked(%{allowance: allowance}, units) when allowance < units, do: "Approve first"
  defp blocked(_figures, _units), do: nil

  defp current(%{figures: %{wallet: wallet} = figures, campaign: %{advertiser: wallet}}),
    do: figures

  defp current(_assigns), do: nil

  @impl true
  def render(assigns) do
    figures = current(assigns)
    units = units(%{assigns: assigns})

    assigns =
      assign(assigns,
        chain_figures: figures,
        units: units,
        buy_blocked: figures && units && blocked(figures, units),
        approved?: figures != nil and units != nil and figures.allowance >= units,
        verb: if(assigns.slot.lease, do: "Buy out", else: "Buy"),
        sent:
          assigns.presses
          |> RegentChain.Presses.shown()
          |> Enum.map(&OnchainSteps.describe(&1, Offers.chain().name))
      )

    ~H"""
    <section
      id={@id}
      class="pb-buy"
      phx-hook="OnchainSteps"
      aria-labelledby={"#{@id}-title"}
    >
      <header class="pb-buy-head">
        <h4 id={"#{@id}-title"}>{@verb}</h4>
        <span class="pb-buy-where">Slot {@slot.slot + 1}</span>
        <.link patch={~p"/offers"} class="pb-buy-close" aria-label="Close">
          <Regent.Icons.icon name="x" />
        </.link>
      </header>

      <div :if={@campaigns == []} class="pb-buy-empty">
        <p>Write a campaign first, then choose it here.</p>
        <a href="#offers-new-campaign" class="rg-button rg-button--secondary">
          <span class="rg-button__label">New campaign</span>
        </a>
      </div>

      <form
        :if={@campaigns != []}
        id={"#{@id}-form"}
        class="pb-buy-form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <Primitives.field id={"#{@id}-campaign"} label="Campaign">
          <select id={"#{@id}-campaign"} name="campaign" data-onchain-input="campaign">
            <option
              :for={campaign <- @campaigns}
              value={campaign.id}
              selected={@campaign && campaign.id == @campaign.id}
            >
              {campaign.title}
            </option>
          </select>
        </Primitives.field>
        <Primitives.field id={"#{@id}-amount"} label="Amount">
          <div class="pb-amount">
            <input
              id={"#{@id}-amount"}
              name="amount"
              type="text"
              inputmode="decimal"
              autocomplete="off"
              value={@amount}
              data-onchain-input="amount"
            />
            <span class="pb-amount-unit">USDC</span>
          </div>
          <:hint>
            Minimum {Words.usdc((@chain_figures && @chain_figures.minimum) || @slot.minimum_usdc)} USDC
          </:hint>
        </Primitives.field>
      </form>

      <dl :if={@campaign} class="pb-buy-figures">
        <div>
          <dt>Paying from</dt>
          <dd>
            <Primitives.address id={"#{@id}-from"} address={@campaign.advertiser} variant="compact" />
          </dd>
        </div>
        <div>
          <dt>Balance</dt>
          <dd>
            <Primitives.figure value={
              if @chain_figures, do: "#{Words.usdc(@chain_figures.balance)} USDC", else: "—"
            } />
          </dd>
        </div>
      </dl>

      <p class="pb-buy-refusal" role="status" hidden={!@refusal}>
        <OnchainSteps.note :if={@refusal} id={"#{@id}-refusal"} parts={@refusal} />
      </p>

      <div :if={@campaign && !@refusal} class="pb-buy-steps">
        <div class="pb-step">
          <button
            type="button"
            class={["rg-button", "rg-button--secondary", "pb-step-button"]}
            data-onchain-step="approve"
            data-done={@approved?}
          >
            <span class="rg-button__label">
              <Primitives.tick done={@approved?} />
              {if @units, do: "Approve #{Words.usdc(@units)} USDC", else: "Approve"}
            </span>
          </button>
        </div>
        <div class="pb-step">
          <button
            type="button"
            class={["rg-button", "rg-button--primary", "pb-step-button"]}
            data-onchain-step="buy"
            disabled={@buy_blocked != nil}
            aria-describedby={@buy_blocked && "#{@id}-why"}
          >
            <span class="rg-button__label">{@verb}</span>
          </button>
          <p :if={@buy_blocked} id={"#{@id}-why"} class="pb-step-why">{@buy_blocked}</p>
        </div>
      </div>

      <p :if={@figures_read == :failed} class="pb-buy-unread">
        Base couldn't be read just now. Figures may be out of date.
      </p>

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
          <span class="pb-sent-name">{step_name(entry.name, @verb)}</span>
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
    </section>
    """
  end

  defp step_name("approve", _verb), do: "Approve"
  defp step_name(_buy, verb), do: verb
end
