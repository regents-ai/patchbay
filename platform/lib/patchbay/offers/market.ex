defmodule Patchbay.Offers.Market do
  @moduledoc """
  Reads of Patchbay's market and of USDC at the latest block, for the wallet
  buttons: a slot's lease and minimum price, a placement's state, a wallet's
  credit, and how much USDC a wallet holds and lets the market take. Each
  read is one call through the configured client (`Patchbay.Offers.Client`).
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.{Client, Contract}
  alias RegentChain.{Abi, Call}

  @doc "One slot's lease; an empty slot reads all zeros but its nonce."
  @spec lease(pos_integer(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def lease(placement_id, slot) do
    with {:ok, {buyer, campaign_id, paid, starts_at, ends_at, nonce}} <-
           read(Contract.get_lease(placement_id, slot)) do
      {:ok,
       %{
         buyer: String.downcase(buyer),
         campaign_id: hex(campaign_id),
         paid_usdc: paid,
         starts_at: starts_at,
         ends_at: ends_at,
         nonce: nonce
       }}
    end
  end

  @doc "When the placement was terminated, or nil while it is open."
  @spec terminated_at(pos_integer()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def terminated_at(placement_id) do
    case read(Contract.get_placement(placement_id)) do
      {:ok, {_source, _terms, 0}} -> {:ok, nil}
      {:ok, {_source, _terms, seconds}} -> {:ok, DateTime.from_unix!(seconds)}
      error -> error
    end
  end

  @doc "The least a purchase of the slot must pay now, in USDC base units."
  @spec minimum_price(pos_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def minimum_price(placement_id, slot), do: read(Contract.minimum_price(placement_id, slot))

  @doc "What `wallet` may take from the market with `claim`, in USDC base units."
  @spec claimable(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def claimable(wallet), do: read(Contract.claimable(wallet))

  @doc "How much USDC `wallet` lets the market take."
  @spec allowance(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def allowance(wallet),
    do: usdc(Call.encode("allowance(address,address)", [wallet, Offers.market()]))

  @doc "How much USDC `wallet` holds."
  @spec balance(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def balance(wallet), do: usdc(Call.encode("balanceOf(address)", [wallet]))

  defp read(tx_data) do
    with {:ok, returned} <-
           Client.configured().call(Offers.market(), Ethers.Utils.hex_encode(tx_data.data)),
         {:ok, bytes} <- Abi.bytes(returned) do
      Ethers.TxData.abi_decode(bytes, tx_data, :output)
    else
      :error -> {:error, :unreadable_answer}
      error -> error
    end
  end

  defp usdc(data) do
    with {:ok, returned} <- Client.configured().call(Offers.usdc(), data),
         {:ok, bytes} <- Abi.bytes(returned),
         {:ok, [amount]} <- Abi.decode(bytes, [{:uint, 256}]) do
      {:ok, amount}
    else
      :error -> {:error, :unreadable_answer}
      error -> error
    end
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
