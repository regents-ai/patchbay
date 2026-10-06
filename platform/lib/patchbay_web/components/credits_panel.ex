defmodule PatchbayWeb.CreditsPanel do
  @moduledoc """
  The Buy Credits panel, as in the Regent template: the balance, the amount,
  the chain, the wallet presses and what each press did, all in one place. The
  server builds the steps (`RegentCredits.Chains.steps/3`), every press goes
  straight to the wallet, and each sent Buy is reported as a purchase, then
  checked every two seconds until it counts. Patchbay's Oban keeps checking
  once a minute after the page stops.

  It pays from the wallet Patchbay knows the profile by, shown as soon as the
  panel opens. The press reaches Privy's active wallet; when that is another
  wallet, nothing is sent and the panel names both.

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
       amount: "10",
       chain: "base",
       number: Ecto.UUID.generate(),
       numbers: %{},
       usdc: nil,
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
    %{linked: linked, active: active, chain: chain} = socket.assigns

    {:noreply,
     assign(socket, press_note: failure_note(reason, linked, active, chain_name(chain)))}
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

  def handle_async(:usdc, {:ok, {:ok, micro}}, socket),
    do: {:noreply, assign(socket, usdc: micro)}

  def handle_async(:usdc, _unread, socket), do: {:noreply, assign(socket, usdc: :unread)}

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

  defp failure_note(reason, linked, active, chain_name),
    do: OnchainSteps.failure_note(reason, linked, active, chain_name)

  defp choose(socket, amount, chain) do
    socket = assign(socket, amount: amount)

    if Map.has_key?(@chains, chain) and chain != socket.assigns.chain,
      do: assign(socket, chain: chain, usdc: nil),
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
        else: assign(socket, signer: signer, usdc: nil)

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
    %{chain: chain, signer: signer} = socket.assigns
    chain = @chains[chain]

    start_async(socket, :usdc, fn ->
      call = %{to: Chains.usdc(chain), data: Call.encode("balanceOf(address)", [signer])}

      with {:ok, "0x" <> hex} <-
             ChainClient.rpc(Chains.chain(chain), "eth_call", [call, "latest"]) do
        {:ok, String.to_integer(hex, 16)}
      end
    end)
  end

  defp dollars(amount) do
    case Integer.parse(String.trim(amount)) do
      {n, ""} when n in 5..500 -> n
      _not_whole_dollars -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="credits-panel" phx-hook="PatchbayCreditsPanel">
      <header class="credits-panel__head">
        <h2>Buy Credits</h2>
        <p class="credits-panel__balance">
          <span>Balance</span>
          <strong>{Amount.format(@balance.available)}</strong>
          <span :if={Decimal.gt?(@balance.held, 0)} class="credits-panel__muted">
            and {Amount.format(@balance.held)} held for bids and posts
          </span>
        </p>
        <p class="credits-panel__muted">One Credit is one US dollar.</p>
      </header>

      <form
        id={"#{@id}-form"}
        class="credits-panel__form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <label for={"#{@id}-amount"}>Amount in US dollars, from 5 to 500</label>
        <input
          id={"#{@id}-amount"}
          name="amount"
          value={@amount}
          inputmode="numeric"
          autocomplete="off"
          data-onchain-input="amount"
        />

        <fieldset class="credits-panel__chains">
          <legend>Pay with USDC on</legend>
          <label :for={{value, label} <- [{"base", "Base"}, {"ethereum", "Ethereum"}]}>
            <input
              type="radio"
              name="chain"
              value={value}
              checked={@chain == value}
              data-onchain-input="chain"
            />
            {label}
          </label>
        </fieldset>
      </form>

      <%!-- Lines above the buttons stay in the page and are only hidden, so one
           appearing never replaces the button a person has just pressed. --%>
      <p class="credits-panel__line" aria-live="polite">{how(@chain, dollars(@amount))}</p>
      <p class="credits-panel__line" hidden={!@signer}>
        <%= if @signer do %>
          Paying from <code>{RegentFormat.short_address(@signer)}</code>
          on {chain_name(@chain)} · {usdc(@usdc)}
        <% end %>
      </p>
      <p class="credits-panel__note" hidden={!@mismatch}>{@mismatch}</p>

      <div class="credits-panel__actions">
        <P.button :if={@chain == "base"} variant="secondary" data-onchain-step="approve">
          Approve
        </P.button>
        <P.button data-onchain-step="buy">Buy</P.button>
      </div>

      <p :if={@press_note} class="credits-panel__note" role="status">{@press_note}</p>
      <p class="credits-panel__note" role="status" data-onchain-lost hidden>
        This page lost its connection, so nothing was sent. Press again once it's back.
      </p>

      <ol :if={@presses.sent != []} class="credits-panel__sent" aria-live="polite">
        <li
          :for={entry <- @presses.sent}
          data-state={state(entry, @purchases[entry.hash])}
        >
          <strong>{title(entry)}</strong>
          <span>{words(entry, @purchases[entry.hash])}</span>
          <code>{RegentFormat.short_hash(entry.hash)}</code>
          <P.button
            :if={entry.name != "buy" and Presses.stalled?(entry)}
            variant="quiet"
            phx-click="check_again"
            phx-value-hash={entry.hash}
            phx-target={@myself}
          >
            Check again
          </P.button>
          <P.button
            :if={purchase_stalled?(@purchases[entry.hash])}
            variant="quiet"
            phx-click="check_purchase_again"
            phx-value-hash={entry.hash}
            phx-target={@myself}
          >
            Check again
          </P.button>
        </li>
      </ol>

      <footer class="credits-panel__rules">
        <p>
          Purchased Credits can be refunded only while you have never used Credits; placing
          any bid counts as use, even one that came back. Given Credits are never refunded.
          <a href="https://regents.sh/credits/refunds" target="_blank" rel="noopener">Refund rules</a>
          · <a href="/credits-help">Credits help</a>
        </p>
        <p>
          Agents spend from this balance only within the limits you set. All account settings
          live at <a href="https://regents.sh/account" target="_blank" rel="noopener">regents.sh/account</a>.
          Sign in there with the same login you use here.
        </p>
      </footer>
    </section>
    """
  end

  defp how(_chain, nil), do: "Enter a whole number of dollars from 5 to 500."

  defp how("base", dollars),
    do:
      "Two presses: Approve lets REGENT staking take #{dollars} USDC, then Buy sends it. Your #{dollars} Credits arrive in about 2 seconds."

  defp how("ethereum", dollars),
    do:
      "One press: Buy sends #{dollars} USDC to the Regent treasury. Your #{dollars} Credits arrive after 12 Ethereum blocks, about 2½ minutes."

  defp title(%{name: "approve", review: %{inputs: %{"amount" => amount}}}),
    do: "Approve #{amount} USDC"

  defp title(%{name: "buy", review: %{inputs: %{"amount" => amount}}}),
    do: "Buy #{amount} Credits"

  defp title(_unknown), do: "Transaction"

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
        "#{Amount.format(amount)} added."

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

  defp usdc(nil), do: "reading USDC balance"
  defp usdc(:unread), do: "USDC balance unavailable right now"

  defp usdc(micro) do
    dollars = micro |> Decimal.new() |> Decimal.div(1_000_000) |> Decimal.round(2, :down)
    "#{Decimal.to_string(dollars, :normal)} USDC"
  end
end
