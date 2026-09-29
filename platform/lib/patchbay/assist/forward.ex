defmodule Patchbay.Assist.Forward do
  @moduledoc """
  Hands an assist's fee on from the operator wallet to the REGENT revenue
  staking contract on Base, as revenue tagged `patchbay.assist` and
  referenced to the wallet that paid it, through the payments library's fee
  route (`RegentPayments.FeeForward`).

  What came of it is written on the run, with the deposit's transaction hash
  when there is one. A fee that could not be forwarded is left for a person
  to re-run with `run/1`; it never withholds the assist. A deposit that was
  handed to Base without an answer may still land, so the log says to look
  on the chain before running it again.
  """

  require Logger

  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias Patchbay.Escrow
  alias RegentPayments.FeeForward

  @source_tag "patchbay.assist"

  @doc """
  Forwards the run's fee if it is still waiting to be forwarded, and writes
  the outcome on the run. A Patchbay with no staking contract set leaves the
  fee waiting and says so in the log.
  """
  @spec run(Ash.UUID.t()) :: :ok
  def run(run_id) do
    # Patchbay's own worker, on a run that is bought and answers to no request.
    case Assist.get_run(run_id, authorize?: false) do
      {:ok, %Run{deposit_status: :pending} = run} -> forward(run)
      _already_forwarded_or_gone -> :ok
    end
  end

  defp forward(run) do
    case submit(run) do
      {:ok, %{deposit: deposit}} ->
        record(run, :deposited, deposit)

      {:error, :not_configured} ->
        Logger.warning(
          "Assist #{run.id}: fee left in the operator wallet, no staking contract set"
        )

        :ok

      {:error, {:deposit_unknown, %{deposit: deposit}}} ->
        Logger.error(
          "Assist #{run.id}: fee deposit #{inspect(deposit)} was handed to Base with no answer; " <>
            "look on the chain before forwarding it again"
        )

        record(run, :failed, deposit)

      {:error, {:deposit_reverted, %{deposit: deposit}}} ->
        Logger.error("Assist #{run.id}: fee deposit #{deposit} reverted")
        record(run, :failed, deposit)

      {:error, reason} ->
        Logger.error("Assist #{run.id}: fee forward failed: #{inspect(reason)}")
        record(run, :failed, nil)
    end
  end

  defp submit(run) do
    with {:ok, staking} <- staking_address(),
         {:ok, signer} <- Escrow.signer() do
      FeeForward.submit(run.payment_intent_id,
        kind: :jev_assist,
        staking: staking,
        signer: signer,
        source_tag: @source_tag
      )
    end
  end

  defp staking_address do
    case Assist.staking_contract_address() do
      address when is_binary(address) -> {:ok, address}
      nil -> {:error, :not_configured}
    end
  end

  # The one place that hears what the chain said about the fee; the run's
  # deposit action is reachable from nowhere else, so authorization is
  # skipped deliberately.
  defp record(run, status, tx_hash) do
    _ =
      Assist.record_deposit!(run, %{deposit_status: status, deposit_tx_hash: tx_hash},
        authorize?: false
      )

    :ok
  end
end
