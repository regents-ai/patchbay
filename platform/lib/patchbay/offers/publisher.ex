defmodule Patchbay.Offers.Publisher do
  @moduledoc """
  The publisher account that admits purchases in Patchbay's market: its
  address and its key, from `config :patchbay, Patchbay.Offers`
  (`publisher_private_key`). Inspecting it shows only the address, so an
  error or a report that carries it never carries the key.
  """

  @derive {Inspect, only: [:address]}
  @enforce_keys [:address, :private_key]
  defstruct [:address, :private_key]

  @type t :: %__MODULE__{address: String.t(), private_key: String.t()}

  @private_key ~r/\A(?:0x)?[0-9a-fA-F]{64}\z/

  @doc "The publisher account, or `{:error, :closed}` while no valid key is set."
  @spec signer() :: {:ok, t()} | {:error, :closed}
  def signer do
    with key when is_binary(key) <- Patchbay.Offers.settings()[:publisher_private_key],
         key = String.trim(key),
         true <- Regex.match?(@private_key, key),
         {:ok, [address]} <- Ethers.Signer.Local.accounts(private_key: key) do
      {:ok, %__MODULE__{address: String.downcase(address), private_key: key}}
    else
      _missing -> {:error, :closed}
    end
  end

  @doc "True while buying is open: a publisher key is set."
  @spec open?() :: boolean()
  def open?, do: match?({:ok, _publisher}, signer())

  @doc "The 65-byte signature of `digest`, as `0x` hex ending in 27 or 28."
  @spec sign(t(), <<_::256>>) :: String.t()
  def sign(%__MODULE__{private_key: key}, <<_::256>> = digest) do
    {:ok, {r, s, recovery}} = ExSecp256k1.sign(digest, private_key(key))
    "0x" <> Base.encode16(r <> s <> <<recovery + 27>>, case: :lower)
  end

  defp private_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp private_key(hex), do: Base.decode16!(hex, case: :mixed)
end
