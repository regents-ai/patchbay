defmodule Patchbay.Forum.EscrowRevenuePush do
  @moduledoc """
  The `:push_escrow_revenue` action of `Patchbay.Forum.Report`: once a
  bounty has paid out or gone back to its asker, the escrow keeps 10% of it
  for REGENT staking, and this pushes what the escrow keeps into the REGENT
  revenue staking contract (`Patchbay.Escrow.push_revenue/0`). Its job (the
  `:push_escrow_revenue` trigger) runs on the fee queue.

  A push hands over everything the escrow keeps, other bounties' shares
  included, so a bounty is done once its payout is on Base and the escrow
  keeps nothing any more. A release is written as soon as Base has taken it,
  so its payout is waited for first; a refund is only written once the
  contract says it happened. Running twice is safe: the second run finds
  nothing kept and sends nothing.

  A push that would not go through, such as while the staking contract is
  paused, is not sent, and the job tries again later.
  """

  use Ash.Resource.ManualUpdate

  require Logger

  alias Patchbay.Escrow
  alias Patchbay.Forum

  @impl true
  def update(changeset, _opts, _context) do
    report = changeset.data

    with :ok <- payout_landed(report),
         :ok <- nothing_kept(report) do
      # Patchbay's own job writing what the chain said.
      Forum.record_escrow_revenue_pushed(report, authorize?: false)
    end
  end

  defp payout_landed(%{escrow_status: :released} = report),
    do: Escrow.await_landed(report.escrow_release_tx_hash)

  defp payout_landed(_refunded), do: :ok

  defp nothing_kept(report) do
    case Escrow.revenue_owed() do
      {:ok, 0} -> :ok
      {:ok, _kept} -> push(report)
      {:error, reason} -> {:error, reason}
    end
  end

  # What the push leaves kept, if anything (a push the chain reverted, or a
  # payout that landed meanwhile), is pushed on the next try.
  defp push(report) do
    with {:ok, tx_hash} <- Escrow.push_revenue(),
         :ok <- Escrow.await_landed(tx_hash) do
      Logger.info("Report #{report.id}: escrow revenue pushed to REGENT staking in #{tx_hash}")

      case Escrow.revenue_owed() do
        {:ok, 0} -> :ok
        {:ok, _kept} -> {:error, :revenue_still_kept}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
