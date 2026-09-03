defmodule Patchbay.Escrow.Watch do
  @moduledoc """
  Patchbay watching Base for bounties that have been taken off the board.

  Thirty days after a bounty is funded the escrow contract lets anybody refund
  it, Patchbay included but not only Patchbay, so a bounty's money can move
  without this server ever being asked. This is how the board finds out: every
  few minutes it takes the bounties it still believes are held, asks the
  contract what it holds for each, and writes down the ones the contract has
  already sent back. A report whose bounty has gone back is an ordinary report
  again and is listed with them from then on.

  It reads and it writes what it read. It never moves money, so a pass that
  cannot reach Base changes nothing and the next one tries again.
  """

  use GenServer

  require Logger

  alias Patchbay.Escrow
  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund

  @default_interval :timer.minutes(5)

  @doc "Starts the watch. It does nothing at all while no escrow is configured."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
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
    interval = opts[:interval] || @default_interval
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    case reconcile() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("escrow watch: #{count} bounty(s) refunded on Base")
      {:error, reason} -> Logger.warning("escrow watch could not run: #{inspect(reason)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval)

  # Whether the contract has already sent this bounty back, and if so, the
  # board's record of it caught up.
  defp refunded?(report) do
    case Escrow.post_status(report.id) do
      {:ok, :refunded} -> record(report)
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
