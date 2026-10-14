defmodule Patchbay.Forum.WalletSecretTest do
  use ExUnit.Case, async: true

  alias Patchbay.Forum.WalletSecret

  # The published test vectors of BIP-39, Bitcoin's wallet import format and
  # BIP-32; the Solana key is made here.
  @phrase_12 "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
  @phrase_24 String.duplicate("abandon ", 23) <> "art"
  @wif "5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ"
  @wif_compressed "KwdMAjGmerYanjeui5SHS7JkmpZvVipYvB2LJGU1ZxJwYvP98617"
  @xprv "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi"

  test "a wallet's secret is found by what only a real one has; linked hashes, signatures and words are not" do
    assert WalletSecret.find("My seed is #{@phrase_12}, is that safe?") == :recovery_phrase
    assert WalletSecret.find(numbered(@phrase_24)) == :recovery_phrase
    assert WalletSecret.find("restore with `#{@phrase_12}`") == :recovery_phrase

    assert WalletSecret.find(Enum.map_join(String.split(@phrase_12), "\n", &"- #{&1}")) ==
             :recovery_phrase

    assert WalletSecret.find("key: #{@wif}") == :bitcoin_key
    assert WalletSecret.find(@wif_compressed) == :bitcoin_key
    assert WalletSecret.find("restore from #{@xprv}") == :bitcoin_key

    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    assert WalletSecret.find("solana: " <> base58(secret <> public)) == :solana_key
    assert WalletSecret.find(inspect(:binary.bin_to_list(secret <> public))) == :solana_key

    # An Ethereum key looks exactly like a transaction hash, so a bare one is
    # refused either way and a transaction is written as its link.
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    assert WalletSecret.find("my key is #{hex}") == :evm_key
    assert WalletSecret.find("the deposit 0x#{hex} reverted") == :evm_key
    refute WalletSecret.find("the deposit https://basescan.org/tx/0x#{hex} reverted")

    refute WalletSecret.find(
             "[sent](https://etherscan.io/tx/0x#{hex}) and https://mempool.space/tx/#{hex}"
           )

    assert WalletSecret.find("https://basescan.org/tx/0x#{hex} then key #{hex}") == :evm_key

    # An invisible character inside a secret does not hide it.
    assert WalletSecret.find(String.replace(@phrase_12, "about", "ab​out")) ==
             :recovery_phrase

    assert WalletSecret.find("0x​" <> hex) == :evm_key

    # The same words joined the way code joins them, twelve list words whose
    # last does not carry the checksum, a signature, a Solana signature and
    # an ordinary sentence.
    refute WalletSecret.find("{:" <> String.replace(@phrase_12, " ", ", :") <> "}")
    refute WalletSecret.find(String.replace(@phrase_12, " ", "_"))
    refute WalletSecret.find(String.duplicate("abandon ", 12))
    refute WalletSecret.find("0x" <> Base.encode16(:crypto.strong_rand_bytes(65), case: :lower))
    refute WalletSecret.find(base58(:crypto.strong_rand_bytes(64)))
    refute WalletSecret.find("I called export_orders and it returned an empty file again today.")
  end

  defp numbered(phrase) do
    phrase
    |> String.split()
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {word, n} -> "#{n}. #{word}" end)
  end

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  defp base58(bytes) do
    leading = bytes |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    String.duplicate("1", leading) <> digits(:binary.decode_unsigned(bytes), [])
  end

  defp digits(0, acc), do: List.to_string(acc)
  defp digits(n, acc), do: digits(div(n, 58), [Enum.at(@alphabet, rem(n, 58)) | acc])
end
