defmodule Patchbay.Escrow.Watch do
  @moduledoc """
  Patchbay watching Base for what the escrow contract did with bounties.

  Two things happen on the chain that the board only learns by asking. The
  first is confirmation: when a paid report is published, the request to
  record its money is handed to Base, and the bounty is confirmed only once
  the contract itself says the post is funded, from the wallet and for the
  amount that paid. Every half minute this asks the contract about each
  bounty still waiting, and writes down the ones it has confirmed, with the
  chain's own funding time. A credit that goes unconfirmed for too long is
  reported for a person to look at; it is still asked about, and a late
  confirmation still counts.

  The second is refund: thirty days after a bounty is funded the contract
  lets anybody refund it, Patchbay included but not only Patchbay, so a
  bounty's money can move without this server ever being asked. Every few
  minutes this takes the bounties the board still believes are held, asks
  the contract what it holds for each, and writes down the ones the contract
  has already sent back. A report whose bounty has gone back is an ordinary
  report again and is listed with them from then on.

  It reads and it writes what it read. It never moves money and never sends
  anything again, so a pass that cannot reach Base changes nothing and the
  next one tries again.
  """

  use GenServer

  require Logger

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Payments
  alias Patchbay.Payments.SpecialPost

  @default_confirm_interval :timer.seconds(30)
  @default_reconcile_interval :timer.minutes(5)

  @doc "Starts the watch. It does nothing at all while no escrow is configured."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  One pass over the bounties handed to Base and not yet confirmed, returning
  how many the contract confirmed.
  """
  @spec confirm() :: {:ok, non_neg_integer()} | {:error, term()}
  def confirm do
    if Escrow.contract_address() do
      case Forum.credits_to_confirm() do
        {:ok, reports} -> {:ok, Enum.count(reports, &confirmed?/1)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, 0}
    end
  end

  @doc """
  One pass over the bounties the board believes are held, returning how many
  the contract had already refunded.
  """
  @spec reconcile() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile do
    if Escrow.contract_address() do
      case Forum.bounties_to_reconcile() do
        {:ok, reports} -> {:ok, Enum.count(reports, &refunded?/1)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, 0}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      confirm_interval: opts[:confirm_interval] || @default_confirm_interval,
      reconcile_interval: opts[:reconcile_interval] || @default_reconcile_interval
    }

    schedule(:confirm, state.confirm_interval)
    schedule(:reconcile, state.reconcile_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:confirm, state) do
    case confirm() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("escrow watch: #{count} bounty(s) confirmed on Base")
      {:error, reason} -> Logger.warning("escrow watch could not confirm: #{inspect(reason)}")
    end

    schedule(:confirm, state.confirm_interval)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    case reconcile() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("escrow watch: #{count} bounty(s) refunded on Base")
      {:error, reason} -> Logger.warning("escrow watch could not run: #{inspect(reason)}")
    end

    schedule(:reconcile, state.reconcile_interval)
    {:noreply, state}
  end

  defp schedule(pass, interval), do: Process.send_after(self(), pass, interval)

  # Whether the contract has confirmed this bounty from the wallet and for
  # the amount that paid, and if so, the board's record of it caught up. Any
  # other answer leaves the report waiting for the next pass.
  defp confirmed?(report) do
    case Escrow.post(report.id) do
      {:ok, %{status: :funded} = post} -> confirm_as_paid(report, post)
      {:ok, %{status: :none}} -> still_waiting(report)
      {:ok, %{status: moved}} -> attention(report, "the contract says #{moved}")
      {:error, _reason} -> unread(report)
    end
  end

  # A funded post confirms this bounty only when it is the one that was
  # paid: the same amount, from the wallet the receipt names.
  defp confirm_as_paid(report, post) do
    cond do
      post.amount != report.priority_amount_atomic ->
        attention(
          report,
          "the contract holds #{post.amount}, not #{report.priority_amount_atomic}"
        )

      post.payer != paying_wallet(report) ->
        attention(report, "the contract names a different payer")

      true ->
        confirm(report, post.funded_at)
    end
  end

  # The wallet the receipt names, downcased as the contract names it, or nil
  # when the payment cannot be found, which no funded post can match.
  defp paying_wallet(report) do
    case Payments.get_payment_intent(report.payment_intent_id,
           load: [:receipt],
           authorize?: false
         ) do
      {:ok, %{receipt: %{payer_address: payer}}} -> String.downcase(payer)
      _missing -> nil
    end
  end

  defp confirm(report, funded_at) do
    # Recording what the chain said is nobody's request: no actor is on this
    # path, and no policy names the write, so it is made without one.
    case Forum.confirm_escrow_credit(report, %{escrow_funded_at: funded_at}, authorize?: false) do
      {:ok, _credited} ->
        true

      {:error, reason} ->
        Logger.warning("escrow watch could not record a confirmation: #{inspect(reason)}")
        false
    end
  end

  defp still_waiting(report) do
    if SpecialPost.overdue?(report) do
      attention(
        report,
        "unconfirmed #{SpecialPost.attention_after_minutes()} minutes after hand-over"
      )
    else
      false
    end
  end

  # Base not answering is not Base saying no. The error itself stays out of
  # the log, since a transport error can carry the address it was sent to.
  defp unread(report) do
    Logger.warning("escrow watch: Base could not be read for report #{report.id}")
    still_waiting(report)
  end

  defp attention(report, why) do
    Logger.warning("escrow watch: bounty on report #{report.id} needs a person: #{why}")
    false
  end

  # Whether the contract has already sent this bounty back, and if so, the
  # board's record of it caught up.
  defp refunded?(report) do
    case Escrow.post(report.id) do
      {:ok, %{status: :refunded}} -> record(report)
      _held_or_unreachable -> false
    end
  end

  defp record(report) do
    case PriorityRefund.record(report, report.escrow_refund_tx_hash) do
      {:ok, _refunded} ->
        true

      {:error, reason} ->
        Logger.warning("escrow watch could not record a refund: #{inspect(reason)}")
        false
    end
  end
end
