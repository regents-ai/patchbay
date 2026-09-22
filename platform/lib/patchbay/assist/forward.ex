defmodule Patchbay.Assist.Forward do
  @moduledoc """
  Hands an assist's fee on from the operator wallet to the REGENT revenue
  staking contract on Base, as revenue tagged `patchbay.assist` and
  referenced to the wallet that paid it.

  The fee arrives in the operator wallet as a plain USDC transfer, which is
  all an x402 payment can be. From there it takes two transactions signed
  with the operator key: an approval of exactly the fee to the staking
  contract, and the deposit itself once the approval is on the chain. What
  came of it is written on the run, with the deposit's transaction hash.
  A fee that could not be forwarded is left for a person to re-run with
  `run/1`; it never withholds the assist.
  """

  require Logger

  alias Ethers.Contracts.ERC20
  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias Patchbay.Assist.Staking
  alias Patchbay.Escrow
  alias Patchbay.Payments
  alias Patchbay.Payments.USDC

  @source_tag "patchbay.assist"
  @receipt_every_ms 2_000
  @receipt_tries 30

  @doc "The tag the deposit carries on the chain, as the contract's 32 bytes."
  @spec source_tag() :: <<_::256>>
  def source_tag, do: String.pad_trailing(@source_tag, 32, <<0>>)

  @doc "The reference the deposit carries: the paying wallet, left-padded to 32 bytes."
  @spec source_ref(String.t()) :: <<_::256>>
  def source_ref("0x" <> hex) when byte_size(hex) == 40 do
    <<0::size(96), Base.decode16!(hex, case: :mixed)::binary-size(20)>>
  end

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
      {:ok, tx_hash} ->
        record(run, :deposited, tx_hash)

      {:error, :not_configured} ->
        Logger.warning(
          "Assist #{run.id}: fee left in the operator wallet, no staking contract set"
        )

        :ok

      {:error, reason} ->
        Logger.error("Assist #{run.id}: fee forward failed: #{inspect(reason)}")
        record(run, :failed, nil)
    end
  end

  @doc """
  Sends the approval and the deposit for the run's fee, and returns the
  deposit's transaction hash once the chain has it.
  """
  @spec submit(Run.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(%Run{} = run) do
    with {:ok, staking} <- staking_address(),
         {:ok, signer} <- Escrow.signer(),
         {:ok, %{amount: amount, payer: payer}} <- payment(run),
         {:ok, approval} <- send(ERC20.approve(staking, amount), USDC.asset(), signer),
         :ok <- mined(approval, signer),
         {:ok, deposit} <-
           send(Staking.deposit_usdc(amount, source_tag(), source_ref(payer)), staking, signer),
         :ok <- mined(deposit, signer) do
      {:ok, deposit}
    end
  rescue
    # Whatever went wrong, the exception is raised from a call that was handed
    # the operator key, so it is named and not carried.
    _exception -> {:error, :submit_failed}
  end

  # The fee and the wallet it came from, as the settled payment recorded them.
  defp payment(run) do
    # The worker reads the payment its own run was bought with.
    case Payments.get_payment_intent(run.payment_intent_id, authorize?: false, load: [:receipt]) do
      {:ok, %{amount_atomic: amount, receipt: %{payer_address: payer}}} when is_binary(payer) ->
        {:ok, %{amount: amount, payer: payer}}

      {:ok, _no_receipt} ->
        {:error, :no_receipt}

      {:error, error} ->
        {:error, error}
    end
  end

  defp send(tx_data, to, signer) do
    Ethers.send_transaction(tx_data,
      from: signer.address,
      to: to,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: signer.private_key],
      rpc_opts: [url: signer.rpc_url]
    )
  end

  # Waits for the chain to take the transaction: Base seals a block every two
  # seconds, so the receipt is read on that beat, for a minute at most.
  defp mined(tx_hash, signer), do: mined(tx_hash, signer, @receipt_tries)

  defp mined(_tx_hash, _signer, 0), do: {:error, :not_mined}

  defp mined(tx_hash, signer, tries_left) do
    case Ethers.get_transaction_receipt(tx_hash, rpc_opts: [url: signer.rpc_url]) do
      {:ok, %{"status" => "0x1"}} ->
        :ok

      {:ok, %{"status" => _reverted}} ->
        {:error, {:reverted, tx_hash}}

      _not_yet ->
        Process.sleep(@receipt_every_ms)
        mined(tx_hash, signer, tries_left - 1)
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
