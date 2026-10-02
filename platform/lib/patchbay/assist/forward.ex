defmodule Patchbay.Assist.Forward do
  @moduledoc """
  The `:forward_fee` action of `Patchbay.Assist.Run`: hands an assist's fee
  on from the operator wallet to the REGENT revenue staking contract on Base,
  as revenue tagged `patchbay.assist` and referenced to the wallet that paid
  it, through the payments library's fee route (`RegentPayments.FeeForward`).
  Its job (the `:forward_fee` trigger) forwards one fee at a time.

  The fee's forward is taken (`:take_fee`) in a write of its own before
  anything is sent, and only a fee still waiting can be taken, so a job that
  runs twice, after a retry or rescued from a node that died, forwards one
  fee once. The guard is that write: the payments library leaves stopping a
  second forward to the site, and a deposit carries the paying wallet, not
  the fee, so the chain has nothing to check one fee against.

  A forward that sent nothing is put back and tried again, and after its
  last try is marked failed for a person. A deposit the chain reverted, or
  one handed to Base with no answer, is marked failed with its hash and
  never re-run blind: the second may still land, so a person looks on the
  chain first. A Patchbay with no staking contract or operator key set
  leaves the fee waiting and says so in the log. What came of it never
  withholds the assist.
  """

  use Ash.Resource.ManualUpdate

  require Logger

  alias Patchbay.Assist
  alias Patchbay.Escrow
  alias RegentPayments.FeeForward

  @source_tag "patchbay.assist"

  # The fee's actions are reachable from nowhere else, so each call below
  # skips authorization deliberately.
  @impl true
  def update(changeset, _opts, _context) do
    run = changeset.data

    case configured() do
      {:ok, staking, signer} ->
        # Patchbay's own job on a run that is bought and answers to no request.
        with {:ok, taken} <- Assist.take_fee(run, authorize?: false),
             do: forward(taken, staking, signer)

      {:error, :not_configured} ->
        Logger.warning(
          "Assist #{run.id}: fee left in the operator wallet, no staking contract or operator key set"
        )

        {:ok, run}
    end
  end

  defp forward(run, staking, signer) do
    case FeeForward.submit(run.payment_intent_id,
           kind: :jev_assist,
           staking: staking,
           signer: signer,
           source_tag: @source_tag
         ) do
      {:ok, %{deposit: deposit}} ->
        # Patchbay's own job writing what the chain said.
        Assist.record_deposited(run, %{deposit_tx_hash: deposit}, authorize?: false)

      {:error, {:deposit_unknown, %{deposit: deposit}}} ->
        Logger.error(
          "Assist #{run.id}: fee deposit #{inspect(deposit)} was handed to Base with no answer; " <>
            "look on the chain before forwarding it again"
        )

        failed(run, deposit)

      {:error, {:deposit_reverted, %{deposit: deposit}}} ->
        Logger.error("Assist #{run.id}: fee deposit #{deposit} reverted")
        failed(run, deposit)

      {:error, reason} ->
        # Nothing left the operator wallet, so the fee waits for the next try;
        # Patchbay's own job puts it back.
        with {:ok, _released} <- Assist.release_fee(run, authorize?: false),
             do: {:error, {:fee_not_forwarded, reason}}
    end
  end

  defp configured do
    with staking when is_binary(staking) <- Assist.staking_contract_address(),
         {:ok, signer} <- Escrow.signer() do
      {:ok, staking, signer}
    else
      _missing -> {:error, :not_configured}
    end
  end

  # Patchbay's own job writing what the chain said.
  defp failed(run, tx_hash),
    do: Assist.record_fee_failed(run, %{deposit_tx_hash: tx_hash}, authorize?: false)
end
