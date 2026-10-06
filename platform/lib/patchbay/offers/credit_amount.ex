defmodule Patchbay.Offers.CreditAmount do
  @moduledoc """
  Credit amounts as Agent Offers reads and writes them.

  One hundredth of a Credit is one integer minor unit. An amount arrives as a
  decimal string with at most two fractional digits ("12", "12.5", "12.50")
  and is never parsed through a float. Signs, exponents, spaces and more than
  two fractional digits are refused, as is anything with more than fifteen
  whole digits, so every amount fits a `bigint` column.
  """

  # 999,999,999,999,999.99 Credits, the most fifteen whole digits can say.
  @max_minor 99_999_999_999_999_999

  @doc "The largest amount, in minor units, an Offer amount may be."
  @spec max_minor() :: pos_integer()
  def max_minor, do: @max_minor

  @doc """
  The minor units for a decimal string, or `:error`.

      iex> Patchbay.Offers.CreditAmount.parse("11.02")
      {:ok, 1102}
      iex> Patchbay.Offers.CreditAmount.parse("1e3")
      :error
  """
  @spec parse(term()) :: {:ok, non_neg_integer()} | :error
  def parse(text) when is_binary(text) do
    case Regex.run(~r/\A(\d{1,15})(?:\.(\d{1,2}))?\z/, text) do
      [_, whole] -> {:ok, String.to_integer(whole) * 100}
      [_, whole, cents] -> {:ok, String.to_integer(whole) * 100 + cents_minor(cents)}
      nil -> :error
    end
  end

  def parse(_other), do: :error

  defp cents_minor(<<tenths>>), do: (tenths - ?0) * 10
  defp cents_minor(cents), do: String.to_integer(cents)

  @doc """
  The decimal string for minor units, always with two fractional digits.

      iex> Patchbay.Offers.CreditAmount.format(12650)
      "126.50"
  """
  @spec format(non_neg_integer()) :: String.t()
  def format(minor) when is_integer(minor) and minor >= 0 do
    whole = div(minor, 100)
    cents = rem(minor, 100)
    "#{whole}." <> String.pad_leading(Integer.to_string(cents), 2, "0")
  end

  @doc """
  The same amount in whole Credits, exactly, as the Credits ledger takes it.

      iex> Patchbay.Offers.CreditAmount.to_credits(1102)
      Decimal.new("11.02")
  """
  @spec to_credits(non_neg_integer()) :: Decimal.t()
  def to_credits(minor) when is_integer(minor) and minor >= 0, do: Decimal.new(1, minor, -2)

  @doc """
  Whole Credits as minor units, rounded up to the hundredth: the least a
  hundredths amount must be to cover them.

      iex> Patchbay.Offers.CreditAmount.from_credits(Decimal.new("3.001"))
      301
  """
  @spec from_credits(Decimal.t()) :: non_neg_integer()
  def from_credits(%Decimal{} = credits) do
    credits |> Decimal.mult(100) |> Decimal.round(0, :ceiling) |> Decimal.to_integer()
  end
end
