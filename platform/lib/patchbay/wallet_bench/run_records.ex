defmodule Patchbay.WalletBench.RunRecords do
  @moduledoc """
  Each run's public record from Techtree (`Patchbay.WalletBench.PublicRun`), as
  a pair's page shows the run chosen on it. A record is kept on this machine for
  five minutes and shared by every visitor to that run, so a crowd on one run's
  page reads Techtree once in that time. Visitors who arrive together while the
  record is being read wait for that one read rather than each starting their
  own. A failed read is kept for one minute, so while Techtree is down each run
  is asked again at most once a minute, and its page says the run did not load.

  A record is kept under the run's attempt, agent and wallet, the three things
  `PublicRun.valid?/2` checks it against.
  """
  use Nebulex.Cache, otp_app: :patchbay, adapter: Nebulex.Adapters.Local

  alias Patchbay.WalletBench.PublicRun

  @kept :timer.minutes(5)
  @failure_kept :timer.minutes(1)

  @spec read(map()) :: {:ok, map()} | {:error, :unavailable}
  def read(run) do
    key = {run.attempt_id, run.harness_id, run.wallet_id}

    case get!(key) do
      nil -> read_once(key, run)
      reading -> reading
    end
  end

  # One read at a time for each run: a visitor who waited on the lock finds the
  # record the first one kept. The wait is as long as that read can take
  # (PublicRun gives up within 12 seconds); a lock whose holder died or held it
  # past 30 seconds is taken over.
  defp read_once(key, run) do
    {:ok, reading} =
      transaction(
        fn ->
          case get!(key) do
            nil -> read_and_keep(key, run)
            reading -> reading
          end
        end,
        keys: [key],
        retries: :infinity,
        retry_interval: 50
      )

    reading
  end

  defp read_and_keep(key, run) do
    reading = PublicRun.fetch(run)
    put!(key, reading, ttl: kept(reading))
    reading
  end

  defp kept({:ok, _report}), do: @kept
  defp kept({:error, _reason}), do: @failure_kept
end
