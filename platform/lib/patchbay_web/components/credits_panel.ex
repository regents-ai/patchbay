defmodule PatchbayWeb.CreditsPanel do
  @moduledoc """
  The Buy Credits panel, as in the Regent template: the balance, the amount,
  the chain, the wallet presses and what each press did, all in one place. The
  server builds the steps (`RegentCredits.Chains.steps/3`), every press goes
  straight to the wallet, and each sent Buy is reported as a purchase, then
  checked every two seconds until it counts. Patchbay's Oban keeps checking
  once a minute after the page stops.

  It pays from the wallet Patchbay knows the profile by, shown as soon as the
  panel opens with its USDC on both chains. The press reaches Privy's active
  wallet; when that is another wallet, nothing is sent and the panel names
  both. The chain starts on the one the wallet is on, until the person picks
  one, and a Switch Chain button asks the wallet onto the picked one.

  The parent passes `profile` (signed in with Privy), its `balance`
  (`RegentCredits.balance/1`, kept current by the parent) and `id`.
  """
  use PatchbayWeb, :live_component

  alias Patchbay.{ChainClient, Credits}
  alias PatchbayWeb.OnchainSteps
  alias Regent.Primitives, as: P
  alias RegentChain.{Call, Presses, Review}
  alias RegentCredits.{Amount, Chains}

  @recheck_ms 2_000
  @purchase_reads 150
  @chains %{"base" => :base, "ethereum" => :ethereum}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init()
     |> assign(
       active: nil,
       signer: nil,
       amount: "5",
       chain: "base",
       chain_chosen?: false,
       wallet_chain: nil,
       number: Ecto.UUID.generate(),
       numbers: %{},
       usdc: %{},
       purchases: %{}
     )}
  end

  @impl true
  def update(%{profile: profile} = assigns, socket) do
    linked = [String.downcase(profile.wallet_address)]
    # Until a press says otherwise, the wallet to pay from is the profile's own.
    active = socket.assigns.active || hd(linked)

    {:ok,
     socket
     |> assign(
       id: assigns.id,
       profile: profile,
       balance: assigns.balance,
       linked: linked,
       active: active
     )
     |> sync()}
  end

  @impl true
  def handle_event("change", %{"amount" => amount, "chain" => chain}, socket),
    do: {:noreply, socket |> choose(amount, chain) |> sync()}

  # The chain the wallet is on, or nil when the page could not read one. Until
  # the person picks a chain, the panel follows the wallet's.
  def handle_event("wallet_chain", %{"chain_id" => id}, socket)
      when is_integer(id) or is_nil(id) do
    socket = assign(socket, wallet_chain: id)

    case chain_of(id) do
      chain when is_binary(chain) and not socket.assigns.chain_chosen? ->
        {:noreply, socket |> assign(chain: chain) |> sync()}

      _keep ->
        {:noreply, socket}
    end
  end

  # A press whose wallet or form the review on the page does not match: the
  # wallet and the form are taken as the page's own, and the reply carries the
  # review for them, or none.
  def handle_event(
        "prepare_and_send",
        %{"form" => %{"amount" => amount, "chain" => chain}, "step" => name} = params,
        socket
      )
      when is_binary(amount) and is_binary(chain) do
    socket = socket |> see_wallet(params) |> choose(amount, chain) |> sync()

    case socket.assigns.review do
      %{} = review when is_binary(name) -> {:reply, %{review: review, send: name}, socket}
      _none -> {:reply, %{}, socket}
    end
  end

  def handle_event("step_sent", %{"transaction_hash" => hash} = params, socket)
      when is_binary(hash) do
    socket = OnchainSteps.sent(socket, params)

    case Enum.find(socket.assigns.presses.sent, &(&1.hash == String.downcase(hash))) do
      %{name: "buy", review: %{} = review} = entry -> {:noreply, report(socket, entry, review)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason} = params, socket)
      when is_binary(reason) do
    socket = socket |> see_wallet(params) |> sync()
    %{linked: linked, active: active, chain: chain, amount: amount} = socket.assigns

    note =
      amount_problem(amount) || failure_note(reason, linked, active, chain_name(chain))

    {:noreply, assign(socket, press_note: note)}
  end

  def handle_event("check_again", %{"hash" => hash}, socket),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("check_purchase_again", %{"hash" => hash}, socket) do
    case socket.assigns.purchases do
      %{^hash => shown} -> {:noreply, check_purchase(socket, hash, %{shown | reads: 0})}
      _unknown -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, socket |> OnchainSteps.checked(hash, result) |> read_usdc()}

  def handle_async({:purchase, hash}, {:ok, {:ok, purchase}}, socket) do
    shown = %{purchase: purchase, reads: socket.assigns.purchases[hash].reads + 1}

    if purchase.status == :checking and shown.reads < @purchase_reads,
      do: {:noreply, check_purchase(socket, hash, shown)},
      else: {:noreply, put_purchase(socket, hash, shown)}
  end

  # An unanswered read counts like any other; the next one tries again.
  def handle_async({:purchase, hash}, _unanswered, socket) do
    %{purchase: purchase, reads: reads} = socket.assigns.purchases[hash]
    shown = %{purchase: purchase, reads: reads + 1}

    if shown.reads < @purchase_reads,
      do: {:noreply, check_purchase(socket, hash, shown)},
      else: {:noreply, put_purchase(socket, hash, shown)}
  end

  def handle_async({:usdc, chain}, {:ok, {:ok, micro}}, socket),
    do: {:noreply, assign(socket, usdc: Map.put(socket.assigns.usdc, chain, micro))}

  def handle_async({:usdc, chain}, _unread, socket),
    do: {:noreply, assign(socket, usdc: Map.put(socket.assigns.usdc, chain, :unread))}

  # The wallet Privy had active at the press; `nil` when it had none. A press
  # that could not reach Privy says nothing about the wallet.
  defp see_wallet(socket, %{"active_wallet" => address}) do
    active = OnchainSteps.active_wallet(address)
    socket = if active == socket.assigns.active, do: socket, else: assign(socket, press_note: nil)
    assign(socket, active: active)
  end

  defp see_wallet(socket, _no_wallet_read), do: socket

  # Privy could not be reached, or holds no sign-in in this browser: words of
  # Patchbay's own. Every other reason is the template's.
  defp failure_note("wallet_unreachable", _linked, _active, _chain_name),
    do:
      "Your wallet couldn't be reached from this page. Reload it, then press again. Nothing was sent."

  defp failure_note("privy_signed_out", _linked, _active, _chain_name),
    do: "Sign in again at the top of the page, then press again. Nothing was sent."

  defp failure_note("switch_declined", _linked, _active, chain_name),
    do: "Your wallet stayed where it was. Press Switch Chain to try #{chain_name} again."

  defp failure_note(reason, linked, active, chain_name),
    do: OnchainSteps.failure_note(reason, linked, active, chain_name)

  defp choose(socket, amount, chain) do
    socket = assign(socket, amount: amount)

    if Map.has_key?(@chains, chain) and chain != socket.assigns.chain,
      do: assign(socket, chain: chain, chain_chosen?: true),
      else: socket
  end

  # The review follows the signer, the amount and the chain. A new amount or
  # chain is a new purchase number; a repeat press of the same review buys again
  # under the same number, which is a second purchase.
  defp sync(socket) do
    %{linked: linked, active: active, chain: chain, amount: amount} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    dollars = dollars(amount)
    inputs = %{"amount" => amount, "chain" => chain}

    socket =
      if {inputs, signer} == {socket.assigns[:inputs], socket.assigns.signer},
        do: socket,
        else: assign(socket, inputs: inputs, number: Ecto.UUID.generate())

    review =
      if signer do
        steps =
          if dollars, do: Chains.steps(@chains[chain], dollars, socket.assigns.number), else: []

        Review.new(socket.assigns.id, signer, Chains.chain(@chains[chain]), steps, inputs)
      end

    socket =
      if signer == socket.assigns.signer,
        do: socket,
        else: assign(socket, signer: signer, usdc: %{})

    socket
    |> assign(mismatch: OnchainSteps.mismatch_note(linked, active))
    |> remember_number(review)
    |> OnchainSteps.put_review(review)
    |> read_usdc()
  end

  defp remember_number(socket, nil), do: socket

  defp remember_number(socket, review),
    do: assign(socket, numbers: Map.put(socket.assigns.numbers, review.id, socket.assigns.number))

  defp report(socket, entry, review) do
    %{profile: profile, numbers: numbers} = socket.assigns
    {:ok, actor} = Credits.spender(profile)

    case RegentCredits.report_purchase(
           profile.privy_user_id,
           review.signer,
           @chains[review.inputs["chain"]],
           dollars(review.inputs["amount"]),
           Map.fetch!(numbers, review.id),
           entry.hash,
           actor: actor
         ) do
      {:ok, purchase} -> check_purchase(socket, entry.hash, %{purchase: purchase, reads: 0})
      {:error, _error} -> put_purchase(socket, entry.hash, %{purchase: nil, reads: 0})
    end
  end

  defp check_purchase(socket, hash, shown) do
    {:ok, actor} = Credits.spender(socket.assigns.profile)
    id = shown.purchase.id

    socket
    |> put_purchase(hash, shown)
    |> start_async({:purchase, hash}, fn ->
      Process.sleep(@recheck_ms)
      RegentCredits.check_purchase(id, actor: actor)
    end)
  end

  defp put_purchase(socket, hash, shown),
    do: assign(socket, purchases: Map.put(socket.assigns.purchases, hash, shown))

  defp read_usdc(%{assigns: %{signer: nil}} = socket), do: socket

  defp read_usdc(socket) do
    signer = socket.assigns.signer

    Enum.reduce(Map.values(@chains), socket, fn chain, socket ->
      start_async(socket, {:usdc, chain}, fn -> usdc_of(chain, signer) end)
    end)
  end

  defp usdc_of(chain, signer) do
    call = %{to: Chains.usdc(chain), data: Call.encode("balanceOf(address)", [signer])}

    with {:ok, "0x" <> hex} <-
           ChainClient.rpc(Chains.chain(chain), "eth_call", [call, "latest"]) do
      {:ok, String.to_integer(hex, 16)}
    end
  end

  defp dollars(amount) do
    case Integer.parse(String.trim(amount)) do
      {n, ""} when n in 5..500 -> n
      _not_whole_dollars -> nil
    end
  end

  # Why an amount can't be bought, in words for the person; nil when it can.
  defp amount_problem(amount) do
    case Integer.parse(String.trim(amount)) do
      {n, ""} when n in 5..500 -> nil
      {n, ""} when n < 5 -> "The smallest purchase is 5 USDC."
      {n, ""} when n > 500 -> "The largest purchase is 500 USDC. Buy again for more."
      _not_whole -> "Enter a whole number of USDC, from 5 to 500."
    end
  end

  defp chain_of(8453), do: "base"
  defp chain_of(1), do: "ethereum"
  defp chain_of(_other), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        dollars: dollars(assigns.amount),
        problem: amount_problem(assigns.amount),
        approve: step(assigns, "approve"),
        buy: step(assigns, "buy")
      )

    ~H"""
    <section id={@id} class="credits-panel" phx-hook="PatchbayCreditsPanel">
      <header class="credits-panel__head">
        <dl
          id={"#{@id}-figures"}
          class="credits-panel__figures"
          phx-hook="MotionCount"
          data-variant="flash"
        >
          <div class="credits-panel__figure">
            <dt>Regents Credits</dt>
            <dd data-count>{figure(@balance.available)}</dd>
          </div>
          <div class="credits-panel__figure credits-panel__figure--small">
            <dt>In Bids</dt>
            <dd data-count>{figure(@balance.held)}</dd>
          </div>
        </dl>
        <a
          class="credits-panel__history"
          href="https://regents.sh/account/credits"
          target="_blank"
          rel="noopener"
        >
          Purchase History
        </a>
      </header>

      <form
        id={"#{@id}-form"}
        class="credits-panel__form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <label class="credits-panel__label" for={"#{@id}-amount"}>USDC Amount</label>
        <div class="credits-panel__amount" data-invalid={@problem && "true"}>
          <input
            id={"#{@id}-amount"}
            name="amount"
            value={@amount}
            inputmode="numeric"
            autocomplete="off"
            aria-describedby={"#{@id}-rate #{@id}-problem"}
            aria-invalid={@problem && "true"}
            data-onchain-input="amount"
          />
          <span aria-hidden="true">USDC</span>
        </div>
        <p id={"#{@id}-rate"} class="credits-panel__rate">1 USDC buys 1 Regents Credit</p>
        <p
          id={"#{@id}-problem"}
          class="credits-panel__problem"
          role="alert"
          phx-hook="MotionRefusal"
          data-refused
          hidden={!@problem}
        >
          {@problem}
        </p>

        <div class="credits-panel__chain-row">
          <fieldset class="credits-panel__chains" data-chain={@chain}>
            <legend class="credits-panel__hidden">Pay with USDC on</legend>
            <label :for={{value, name} <- [{"base", "Base"}, {"ethereum", "Ethereum"}]}>
              <input
                type="radio"
                name="chain"
                value={value}
                checked={@chain == value}
                data-onchain-input="chain"
              />
              <.chain_logo chain={value} />
              <span>{name}</span>
            </label>
          </fieldset>
          <P.button
            :if={switch?(@signer, @wallet_chain, @chain)}
            variant="secondary"
            class="credits-panel__switch"
            data-switch-chain
          >
            Switch Chain
          </P.button>
        </div>
        <p :if={switch?(@signer, @wallet_chain, @chain)} class="credits-panel__muted">
          Your wallet is on {wallet_chain_name(@wallet_chain)}.
        </p>
      </form>

      <%!-- Lines above the buttons stay in the page and are only hidden, so one
           appearing never replaces the button a person has just pressed. --%>
      <div class="credits-panel__wallet" hidden={!@signer}>
        <span class="credits-panel__muted">Paying from</span>
        <code>{@signer && RegentFormat.short_address(@signer)}</code>
        <span class="credits-panel__usdc">
          <span>Base {usdc(@usdc[:base])}</span>
          <span>Ethereum {usdc(@usdc[:ethereum])}</span>
        </span>
      </div>
      <p class="credits-panel__note" hidden={!@mismatch}>{@mismatch}</p>

      <ol class="credits-panel__steps">
        <li :if={@chain == "base"} class="credits-panel__step" data-state={@approve.state}>
          <.check />
          <div class="credits-panel__step-words">
            <strong>Approve {@dollars && "#{@dollars} "}USDC</strong>
            <span>{@approve.words || "Lets REGENT staking take the USDC."}</span>
          </div>
          <P.button variant="secondary" data-onchain-step="approve">Approve</P.button>
          <.check_again step={@approve} myself={@myself} />
        </li>
        <li
          class="credits-panel__step"
          data-state={@buy.state}
          data-waiting={@chain == "base" and @approve.state != :done and "true"}
        >
          <.check />
          <div class="credits-panel__step-words">
            <strong>Buy {@dollars && "#{@dollars} "}Credits</strong>
            <span>{@buy.words || arrival(@chain)}</span>
          </div>
          <P.button data-onchain-step="buy">Buy</P.button>
          <.check_again step={@buy} myself={@myself} />
        </li>
      </ol>

      <p :if={@press_note} class="credits-panel__note" role="status">{@press_note}</p>
      <p class="credits-panel__note" role="status" data-onchain-lost hidden>
        This page lost its connection, so nothing was sent. Press again once it's back.
      </p>

      <footer class="credits-panel__legal">
        <a href="https://regents.sh/terms" target="_blank" rel="noopener">Terms of Service</a>
        <a href="https://regents.sh/credits/refunds" target="_blank" rel="noopener">
          Refund Policy
        </a>
      </footer>
    </section>
    """
  end

  attr :chain, :string, required: true

  defp chain_logo(%{chain: "base"} = assigns) do
    ~H"""
    <svg class="credits-panel__logo" viewBox="0 0 111 111" aria-hidden="true">
      <path
        fill="#0052FF"
        d="M54.921 110.034C85.359 110.034 110.034 85.402 110.034 55.017C110.034 24.6319 85.359 0 54.921 0C26.0432 0 2.35281 22.1714 0 50.3923H72.8467V59.6416H0C2.35281 87.8625 26.0432 110.034 54.921 110.034Z"
      />
    </svg>
    """
  end

  defp chain_logo(%{chain: "ethereum"} = assigns) do
    ~H"""
    <svg class="credits-panel__logo" viewBox="0 0 256 417" aria-hidden="true">
      <path fill="#343434" d="M127.961 0l-2.795 9.5v275.668l2.795 2.79 127.962-75.638z" />
      <path fill="#8C8C8C" d="M127.962 0L0 212.32l127.962 75.639V154.158z" />
      <path fill="#3C3C3B" d="M127.961 312.187l-1.575 1.92v98.199l1.575 4.6L256 236.587z" />
      <path fill="#8C8C8C" d="M127.962 416.905v-104.72L0 236.585z" />
      <path fill="#141414" d="M127.961 287.958l127.96-75.637-127.96-58.162z" />
      <path fill="#393939" d="M0 212.32l127.96 75.638v-133.8z" />
    </svg>
    """
  end

  defp check(assigns) do
    ~H"""
    <span class="credits-panel__check" aria-hidden="true">
      <svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
    </span>
    """
  end

  attr :step, :map, required: true
  attr :myself, :any, required: true

  defp check_again(%{step: %{entry: entry, stalled?: true}} = assigns) do
    assigns = assign(assigns, event: check_event(entry), hash: entry.hash)

    ~H"""
    <P.button
      variant="quiet"
      class="credits-panel__again"
      phx-click={@event}
      phx-value-hash={@hash}
      phx-target={@myself}
    >
      Check again
    </P.button>
    """
  end

  defp check_again(assigns), do: ~H""

  defp check_event(%{name: "buy", review: %{}}), do: "check_purchase_again"
  defp check_event(_entry), do: "check_again"

  # The latest press of the named step for the form as it stands now: its state
  # (`:ready` before any), what it did in words, and whether it waits on a
  # Check again.
  defp step(assigns, name) do
    %{presses: %{sent: sent}, purchases: purchases, inputs: inputs} = assigns

    case Enum.find(sent, &(&1.name == name and match?(%{inputs: ^inputs}, &1.review))) do
      nil ->
        %{state: :ready, words: nil, entry: nil, stalled?: false}

      entry ->
        shown = purchases[entry.hash]

        %{
          state: step_state(state(entry, shown)),
          words: words(entry, shown),
          entry: entry,
          stalled?: stalled?(entry, shown)
        }
    end
  end

  defp step_state(state) when state in [:confirmed, :credited], do: :done
  defp step_state(state) when state in [:pending, :checking, :stalled], do: :pending
  defp step_state(_failed), do: :failed

  defp stalled?(%{name: "buy"}, %{} = shown), do: purchase_stalled?(shown)
  defp stalled?(entry, nil), do: Presses.stalled?(entry)
  defp stalled?(_entry, _shown), do: false

  defp arrival("base"), do: "Your Credits arrive in about 2 seconds."
  defp arrival("ethereum"), do: "Your Credits arrive after 12 blocks, about 2½ minutes."

  defp switch?(nil, _wallet_chain, _chain), do: false
  defp switch?(_signer, nil, _chain), do: false
  defp switch?(_signer, wallet_chain, chain), do: chain_of(wallet_chain) != chain

  defp wallet_chain_name(id) do
    case chain_of(id) do
      nil -> "another network"
      chain -> chain_name(chain)
    end
  end

  defp figure(amount),
    do: amount |> Amount.format() |> String.replace_suffix(" Credits", "")

  defp state(entry, nil), do: OnchainSteps.describe(entry, chain_name_of(entry)).state
  defp state(_entry, %{purchase: nil}), do: :unrecorded
  defp state(_entry, %{purchase: purchase}), do: purchase.status

  defp words(entry, nil), do: OnchainSteps.describe(entry, chain_name_of(entry)).words

  defp words(_entry, %{purchase: nil}),
    do:
      "Your wallet sent this, but this page couldn't record it. If USDC left your wallet, post the link in Credits help."

  defp words(_entry, %{purchase: purchase} = shown) do
    case purchase do
      %{status: :credited, amount: amount} ->
        "Done. #{Amount.format(amount)} added."

      %{status: :failed, reason: "reverted"} ->
        "This did not go through and nothing moved."

      %{status: :failed, reason: "already credited"} ->
        "This payment was already counted."

      %{status: :failed, reason: "not found"} ->
        "#{chain_name(purchase.chain)} never showed this payment, so no Credits were added."

      %{status: :failed} ->
        "This transaction is not the purchase this page prepared, so no Credits were added. If USDC left your wallet, post the link in Credits help."

      %{status: :checking} ->
        checking_words(shown)
    end
  end

  defp checking_words(%{purchase: purchase} = shown) do
    cond do
      purchase_stalled?(shown) ->
        "Still being checked. Your balance updates as soon as it counts, even if you close this page."

      purchase.chain == :ethereum and purchase.block_number ->
        "On Ethereum. Your Credits arrive after 12 blocks, about 2½ minutes."

      true ->
        "Sent. Waiting for #{chain_name(purchase.chain)}."
    end
  end

  defp purchase_stalled?(%{purchase: %{status: :checking}, reads: reads}),
    do: reads >= @purchase_reads

  defp purchase_stalled?(_shown), do: false

  defp chain_name_of(%{review: %{chain: %{name: name}}}), do: name
  defp chain_name_of(_unknown), do: "the network"

  defp chain_name(chain) when chain in ["base", :base], do: "Base"
  defp chain_name(chain) when chain in ["ethereum", :ethereum], do: "Ethereum"

  defp usdc(nil), do: "…"
  defp usdc(:unread), do: "unavailable"

  defp usdc(micro) do
    dollars = micro |> Decimal.new() |> Decimal.div(1_000_000) |> Decimal.round(2, :down)
    "#{Decimal.to_string(dollars, :normal)} USDC"
  end
end
