defmodule Patchbay.Payments.USDC do
  @moduledoc """
  The one currency Patchbay Rewards pays in, and the arithmetic for it.

  USDC has six decimal places, so every amount is carried as a whole number of
  its smallest unit — a tip of 2.00 is the integer 2_000_000 from the moment it
  is read off the wire until it is written back out as text. Nothing here ever
  produces a float, because a rounded tip is a different tip.
  """

  # Circle's USDC on Base mainnet.
  @asset "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @network "eip155:8453"

  @decimals 6
  @unit 1_000_000

  # The EIP-712 domain a wallet signs a USDC transfer authorization under.
  @signing_domain %{"name" => "USD Coin", "version" => "2"}

  # A plain decimal number, no sign, no exponent, no more places than the
  # token has.
  @written ~r/\A\d{1,7}(?:\.\d{1,6})?\z/

  @doc """
  The USDC contract address on Base mainnet.
  """
  @spec asset() :: String.t()
  def asset, do: @asset

  @doc """
  Base mainnet, in the CAIP-2 form the x402 protocol names networks by.
  """
  @spec network() :: String.t()
  def network, do: @network

  @doc """
  The EIP-712 domain a payer's wallet signs a USDC transfer under.
  """
  @spec signing_domain() :: map()
  def signing_domain, do: @signing_domain

  @doc """
  Reads a written amount such as `"2.00"` as whole millionths of a dollar.

  Anything that is not a plain decimal number of at most six places is refused
  rather than rounded.
  """
  @spec parse(term()) :: {:ok, non_neg_integer()} | :error
  def parse(amount) when is_binary(amount) do
    if Regex.match?(@written, amount), do: {:ok, atomic(amount)}, else: :error
  end

  def parse(_amount), do: :error

  @doc """
  Writes whole millionths back as text, always with at least two places.
  """
  @spec format(non_neg_integer()) :: String.t()
  def format(amount_atomic) when is_integer(amount_atomic) and amount_atomic >= 0 do
    places =
      amount_atomic
      |> rem(@unit)
      |> Integer.to_string()
      |> String.pad_leading(@decimals, "0")

    "#{div(amount_atomic, @unit)}.#{significant(places)}"
  end

  @spec atomic(String.t()) :: non_neg_integer()
  defp atomic(amount) do
    {whole, places} =
      case String.split(amount, ".") do
        [whole] -> {whole, ""}
        [whole, places] -> {whole, places}
      end

    String.to_integer(whole) * @unit +
      String.to_integer(String.pad_trailing(places, @decimals, "0"))
  end

  @spec significant(String.t()) :: String.t()
  defp significant(places) do
    case String.trim_trailing(places, "0") do
      trimmed when byte_size(trimmed) < 2 -> String.pad_trailing(trimmed, 2, "0")
      trimmed -> trimmed
    end
  end
end
