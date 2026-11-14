defmodule PatchbayWeb.OnchainSteps do
  @moduledoc """
  The server half of a wallet-button component: the template's
  `AshTemplateWeb.OnchainSteps` (skill `onchain-buttons`), on Patchbay's
  press-time path. Patchbay's wallet bridge loads only when someone presses
  (`assets/js/privy_bridge.tsx`), so every press asks the component for its
  steps (`prepare_and_send`, `assets/js/hooks/onchain_steps.ts`) with the form
  as it is on screen: the component builds a `RegentChain.Review` for that
  press, hands it to `prepared/2`, and the page sends the named step from it.

  The review's signer is the wallet the component's figures belong to, one of
  the signed-in account's own wallets; the page sends only when that is the
  wallet Privy has active, and otherwise says which wallet to open. Every sent
  step is read at the latest block of the review's chain, every quarter
  second, until it lands or the page stops asking. Nothing is kept beyond the
  page. When a step lands, the page process is sent `{#{inspect(__MODULE__)},
  :landed, chain_id}`, so it reads the chain again.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [start_async: 3]

  alias Patchbay.ChainClient
  alias RegentChain.{Outcome, Presses}

  @recheck_ms 250
  # What the hook reports when nothing was sent, or may have been: Patchbay's
  # buttons send transactions only, so no signature is ever left unconfirmed.
  @reasons ~w(step_unknown wallet_unavailable network_mismatch wallet_declined insufficient_funds send_unconfirmed)

  @doc "The assigns a wallet-button component starts with."
  def init(socket), do: assign(socket, presses: Presses.new(), press_note: nil)

  @doc "Keeps the review a press is about to send from, so its report is recognised."
  def prepared(socket, review),
    do: assign(socket, presses: Presses.remember(socket.assigns.presses, review), press_note: nil)

  @doc "The wallet sent a step; it is read from now on against the review it was sent from."
  def sent(socket, params) do
    case Presses.sent(socket.assigns.presses, params) do
      {:ok, entry, presses} -> socket |> assign(presses: presses, press_note: nil) |> check(entry)
      :error -> socket
    end
  end

  @doc """
  Nothing was sent, or the wallet may have sent it: the note the component
  shows, from `failure_note/3`, or none for a report it does not know.
  """
  def failed(socket, params, signer, chain_name) do
    case Presses.failed(params) do
      {:ok, _step, reason} when reason in @reasons ->
        assign(socket, press_note: failure_note(reason, signer, chain_name))

      _unknown ->
        socket
    end
  end

  @doc "Starts reading a step again after the page stopped on its own."
  def check_again(socket, hash) do
    case Presses.check_again(socket.assigns.presses, hash) do
      {nil, _presses} -> socket
      {entry, presses} -> socket |> assign(presses: presses) |> check(entry)
    end
  end

  @doc "One answer from `handle_async({:onchain_step, hash}, result, socket)`."
  def checked(socket, hash, {:exit, _reason}), do: checked(socket, hash, {:ok, :unanswered})

  def checked(socket, hash, {:ok, answer}) do
    case Presses.checked(socket.assigns.presses, hash, answer) do
      {nil, _presses} ->
        socket

      {entry, presses} ->
        socket = assign(socket, presses: presses)

        if entry.outcome == :confirmed,
          do: send(self(), {__MODULE__, :landed, entry.review.chain.chain_id})

        if Presses.reading?(entry), do: check(socket, entry), else: socket
    end
  end

  @doc """
  What to say when a press sent nothing, or may have sent something, as parts
  for `note/1`: words, and `{:address, address}` for the wallet it names.
  `signer` is the wallet the press was for, the one the component's figures
  belong to.
  """
  def failure_note(reason, signer, _chain_name)
      when reason in ~w(step_unknown wallet_unavailable),
      do: [
        "This pays from ",
        {:address, signer},
        ". Open it in your wallet app, then press again. Nothing was sent."
      ]

  def failure_note("network_mismatch", _signer, chain_name),
    do: [
      "Your wallet is on a different network. Switch it to #{chain_name}, then press again. Nothing was sent."
    ]

  def failure_note("wallet_declined", _signer, _chain_name),
    do: ["Your wallet declined this. Nothing was sent."]

  def failure_note("insufficient_funds", _signer, chain_name),
    do: [
      "Your wallet doesn't have enough on #{chain_name} to pay the network fee. Nothing was sent."
    ]

  def failure_note("send_unconfirmed", _signer, _chain_name),
    do: ["Your wallet may have sent this. Check your wallet activity."]

  attr :id, :string, required: true

  attr :parts, :list,
    required: true,
    doc: "words, and `{:address, address}` for each wallet the note names"

  @doc """
  A note from `failure_note/3`: its words, with each wallet it names opening
  and copying its full address (`Regent.Primitives.address`).
  """
  def note(assigns) do
    # Written on one line and left unformatted: a line break between the parts would
    # show as a space before the punctuation that follows an address.
    ~H"""
    <span id={@id} phx-no-format><%= for {part, index} <- Enum.with_index(@parts) do %><%= if is_binary(part) do %>{part}<% else %><Regent.Primitives.address id={"#{@id}-#{index}"} address={elem(part, 1)} /><% end %><% end %></span>
    """
  end

  @doc """
  One sent step as the page shows it: its state and generic words. A component
  names its steps and may say more about them.
  """
  def describe(entry, chain_name) do
    state = if Presses.stalled?(entry), do: :stalled, else: entry.outcome
    %{hash: entry.hash, name: entry.name, state: state, words: words(state, chain_name)}
  end

  defp words(:pending, chain_name), do: "Sent. Waiting for #{chain_name}."

  defp words(:stalled, chain_name),
    do: "#{chain_name} has not confirmed this yet. Check again, or look in your wallet activity."

  defp words(:confirmed, _chain_name), do: "Done."
  defp words(:reverted, _chain_name), do: "This did not go through and nothing moved."

  defp words(_not_this_step, _chain_name),
    do:
      "This transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

  defp check(socket, %{step: nil}), do: socket

  defp check(socket, %{hash: hash, reads: reads, review: review, step: step}) do
    start_async(socket, {:onchain_step, hash}, fn ->
      if reads > 0, do: Process.sleep(@recheck_ms)
      Outcome.of(ChainClient, review, step, hash)
    end)
  end
end
