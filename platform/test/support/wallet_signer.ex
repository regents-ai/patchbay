defmodule PatchbayWeb.WalletSigner do
  @moduledoc """
  A synthetic wallet for tests: a key made for the run, its address, and its
  signature over what a page payment's review asks it to sign. It never
  reaches a real chain.
  """

  @doc "A fresh key and its lowercased address."
  def new do
    key = :crypto.strong_rand_bytes(32)
    {:ok, address} = X402.EIP3009.derive_address(key)
    %{key: key, address: String.downcase(address)}
  end

  @doc "`wallet`'s signature over the typed data in `review`'s one signature step."
  def sign(%{key: key}, %{"steps" => [%{"kind" => "signature", "typed_data" => typed_data}]}) do
    {:ok, digest} = X402.EIP3009.eip712_digest(typed_data["domain"], typed_data["message"])
    {:ok, {signature, recovery}} = ExSecp256k1.sign_compact(digest, key)
    "0x" <> Base.encode16(signature <> <<recovery + 27>>, case: :lower)
  end
end
