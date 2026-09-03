defmodule Patchbay.Escrow do
  @moduledoc """
  Patchbay's relayer to the PatchbayEscrow contract on Base: the operator
  account that records a paid priority report's money against its post and,
  once the asker has accepted an answer, pays that answer's author out of it.

  Every call here is one transaction, signed locally with the operator key
  and handed to the chain. It comes back with the transaction hash the moment
  the chain has taken it; nothing waits for the receipt, so a caller records
  the hash and moves on. The three values it needs, the contract address, the
  operator key and the RPC endpoint, are read from `config :patchbay, :escrow`
  and nowhere else. Nothing here ever writes the key anywhere: not into a
  log, not into an error, not into a result.

  A post on the contract is named by its report's id, as 32 bytes: the 16
  raw bytes of the uuid, left-padded with 16 zero bytes. Both the credit and
  the release derive it here, so the two cannot name a post differently.
  """

  alias Patchbay.Escrow.Contract

  @private_key ~r/\A(?:0x)?[0-9a-fA-F]{64}\z/

  @doc """
  The contract address paid-priority money is held at, or nil when this
  Patchbay has none set.
  """
  @spec contract_address() :: String.t() | nil
  def contract_address, do: present(settings()[:contract_address])

  @doc """
  Records `amount_atomic` of USDC from `payer_address` in escrow against the
  report, and returns the hash of the transaction that does it.
  """
  @spec credit(Ash.UUID.t(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def credit(report_id, payer_address, amount_atomic) do
    report_id
    |> post_id()
    |> Contract.credit(payer_address, amount_atomic)
    |> submit()
  end

  @doc """
  Pays the money held against the report out to `winner_address`, and returns
  the hash of the transaction that does it.
  """
  @spec release(Ash.UUID.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def release(report_id, winner_address) do
    report_id
    |> post_id()
    |> Contract.release(winner_address)
    |> submit()
  end

  @doc """
  The contract's name for a report: its uuid's 16 raw bytes, left-padded with
  16 zero bytes to the 32 the contract keys posts by.
  """
  @spec post_id(Ash.UUID.t()) :: <<_::256>>
  def post_id(report_id) do
    {:ok, raw} = Ecto.UUID.dump(report_id)
    <<0::size(128), raw::binary-size(16)>>
  end

  defp submit(tx_data) do
    with {:ok, operator} <- operator() do
      Ethers.send_transaction(tx_data,
        from: operator.address,
        to: operator.contract_address,
        signer: Ethers.Signer.Local,
        signer_opts: [private_key: operator.private_key],
        rpc_opts: [url: operator.rpc_url]
      )
    end
  rescue
    # Whatever went wrong, the exception is raised from a call that was handed
    # the operator key, so it is named and not carried.
    _exception -> {:error, :submit_failed}
  end

  # The operator as configured, or `:not_configured` when any of the three
  # values is missing. The key is only ever handed to the signer.
  defp operator do
    settings = settings()

    with contract_address when is_binary(contract_address) <-
           present(settings[:contract_address]),
         rpc_url when is_binary(rpc_url) <- present(settings[:rpc_url]),
         private_key when is_binary(private_key) <- private_key(settings[:operator_private_key]),
         {:ok, [address]} <- Ethers.Signer.Local.accounts(private_key: private_key) do
      {:ok,
       %{
         address: address,
         contract_address: contract_address,
         private_key: private_key,
         rpc_url: rpc_url
       }}
    else
      _missing -> {:error, :not_configured}
    end
  end

  # A key that is not 32 bytes of hex is no key, so it is treated as unset
  # rather than handed to the signer.
  defp private_key(value) do
    case present(value) do
      key when is_binary(key) -> if Regex.match?(@private_key, key), do: key, else: nil
      nil -> nil
    end
  end

  defp settings, do: Application.get_env(:patchbay, :escrow, [])

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
