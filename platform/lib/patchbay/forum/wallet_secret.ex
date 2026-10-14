defmodule Patchbay.Forum.WalletSecret do
  @moduledoc """
  Finds a wallet's secret in words about to be made public: a recovery phrase
  (the BIP-39 words Ethereum, Bitcoin and Solana wallets all use), a Bitcoin
  private key or extended private key, or a Solana secret key. Whoever reads
  one can take what the wallet holds, so a post carrying one is refused, not
  flagged.

  Each is recognised by something only a real secret has, never by its shape
  alone: a recovery phrase's and a Bitcoin key's own checksum, and a Solana
  key whose second half is the public key of its first. A transaction hash,
  a signature or a run of ordinary words does not match.
  """

  @typedoc "Which kind of secret the text holds."
  @type kind :: :recovery_phrase | :bitcoin_key | :solana_key

  @words "priv/bip39/english.txt"
         |> File.read!()
         |> String.split("\n", trim: true)

  @external_resource "priv/bip39/english.txt"

  @index @words |> Enum.with_index() |> Map.new()

  # A recovery phrase is 12, 15, 18, 21 or 24 words, longest first so the
  # whole phrase is the one found.
  @phrase_lengths [24, 21, 18, 15, 12]

  @base58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @base58_value @base58 |> Enum.with_index() |> Map.new()

  @wif ~r/(?<![1-9A-HJ-NP-Za-km-z])[59KLc][1-9A-HJ-NP-Za-km-z]{50,51}(?![1-9A-HJ-NP-Za-km-z])/
  @extended ~r/(?<![1-9A-HJ-NP-Za-km-z])[xyztuvYZUV]prv[1-9A-HJ-NP-Za-km-z]{100,108}(?![1-9A-HJ-NP-Za-km-z])/
  @solana_text ~r/(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{85,90}(?![1-9A-HJ-NP-Za-km-z])/
  @solana_bytes ~r/\[\s*(?:\d{1,3}\s*,\s*){63}\d{1,3}\s*\]/

  @said %{
    recovery_phrase: "a wallet's recovery phrase",
    bitcoin_key: "a Bitcoin private key",
    solana_key: "a Solana secret key"
  }

  @doc "The kind of wallet secret `text` holds, or `nil`."
  @spec find(term()) :: kind() | nil
  def find(text) when is_binary(text) do
    cond do
      recovery_phrase?(text) -> :recovery_phrase
      bitcoin_key?(text) -> :bitcoin_key
      solana_key?(text) -> :solana_key
      true -> nil
    end
  end

  def find(_text), do: nil

  @doc "What a found secret is called in a sentence."
  @spec said(kind()) :: String.t()
  def said(kind), do: Map.fetch!(@said, kind)

  # Every run of consecutive list words, each window of a phrase's length
  # checked against the checksum its last word carries.
  defp recovery_phrase?(text) do
    ~r/[a-z]+/
    |> Regex.scan(String.downcase(text))
    |> Enum.map(fn [word] -> Map.get(@index, word) end)
    |> Enum.chunk_by(&is_nil/1)
    |> Enum.any?(fn run -> is_integer(hd(run)) and phrase_in?(run) end)
  end

  defp phrase_in?(run) do
    Enum.any?(@phrase_lengths, fn length ->
      length <= length(run) and
        run |> Enum.chunk_every(length, 1, :discard) |> Enum.any?(&checksum?/1)
    end)
  end

  defp checksum?(indexes) do
    bits = for index <- indexes, into: <<>>, do: <<index::11>>
    checksum_size = div(bit_size(bits), 33)
    entropy_size = bit_size(bits) - checksum_size
    <<entropy::bitstring-size(entropy_size), checksum::bitstring-size(checksum_size)>> = bits
    <<expected::bitstring-size(checksum_size), _rest::bitstring>> = :crypto.hash(:sha256, entropy)
    checksum == expected
  end

  # Wallet import format: 0x80 (or 0xef on testnet), the 32-byte key, and 0x01
  # when the key is for a compressed public key. An extended private key is
  # 78 bytes. Both carry a four-byte checksum.
  defp bitcoin_key?(text) do
    Enum.any?(matches(@wif, text), &wif?/1) or Enum.any?(matches(@extended, text), &extended?/1)
  end

  defp wif?(candidate) do
    case checked(candidate) do
      {:ok, <<version, _key::binary-32>>} -> version in [0x80, 0xEF]
      {:ok, <<version, _key::binary-32, 0x01>>} -> version in [0x80, 0xEF]
      _other -> false
    end
  end

  defp extended?(candidate), do: match?({:ok, <<_::binary-78>>}, checked(candidate))

  defp checked(candidate) do
    with {:ok, bytes} when byte_size(bytes) > 4 <- base58(candidate) do
      payload_size = byte_size(bytes) - 4
      <<payload::binary-size(payload_size), checksum::binary-4>> = bytes

      <<expected::binary-4, _rest::binary>> =
        :crypto.hash(:sha256, :crypto.hash(:sha256, payload))

      if checksum == expected, do: {:ok, payload}, else: :error
    end
  end

  # A Solana secret key is the 32-byte seed followed by its own public key,
  # written in base58 or as the 64 numbers of a key file.
  defp solana_key?(text) do
    Enum.any?(matches(@solana_text, text), &(&1 |> base58() |> keypair?())) or
      Enum.any?(matches(@solana_bytes, text), &(&1 |> byte_list() |> keypair?()))
  end

  defp keypair?({:ok, <<seed::binary-32, public::binary-32>>}) do
    {derived, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    derived == public
  end

  defp keypair?(_bytes), do: false

  defp byte_list(candidate) do
    numbers = ~r/\d+/ |> Regex.scan(candidate) |> Enum.map(fn [n] -> String.to_integer(n) end)
    if Enum.all?(numbers, &(&1 <= 255)), do: {:ok, :binary.list_to_bin(numbers)}, else: :error
  end

  defp matches(pattern, text), do: pattern |> Regex.scan(text) |> Enum.map(&hd/1)

  defp base58(candidate) do
    {zeros, rest} = candidate |> String.to_charlist() |> Enum.split_while(&(&1 == ?1))

    value =
      Enum.reduce_while(rest, 0, fn char, acc ->
        case Map.fetch(@base58_value, char) do
          {:ok, digit} -> {:cont, acc * 58 + digit}
          :error -> {:halt, :error}
        end
      end)

    case value do
      :error -> :error
      0 -> {:ok, :binary.copy(<<0>>, length(zeros))}
      value -> {:ok, :binary.copy(<<0>>, length(zeros)) <> :binary.encode_unsigned(value)}
    end
  end
end
