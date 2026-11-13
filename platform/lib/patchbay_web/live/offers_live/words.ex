defmodule PatchbayWeb.OffersLive.Words do
  @moduledoc """
  How the offers page writes its figures and its refusals: USDC amounts, the
  time a lease has left, and why Patchbay will not admit a purchase.
  """

  @unit 1_000_000

  @doc """
  USDC base units as the page shows them: at least two decimals, the rest
  only when there are any, and thousands marked.

      iex> PatchbayWeb.OffersLive.Words.usdc(5_500_000)
      "5.50"
      iex> PatchbayWeb.OffersLive.Words.usdc(1_234_567_891)
      "1,234.567891"
  """
  @spec usdc(non_neg_integer() | Decimal.t()) :: String.t()
  def usdc(%Decimal{} = units), do: units |> Decimal.to_integer() |> usdc()

  def usdc(units) when is_integer(units) do
    whole = units |> div(@unit) |> Integer.to_string() |> thousands()

    fraction =
      units
      |> rem(@unit)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")
      |> String.pad_trailing(2, "0")

    whole <> "." <> fraction
  end

  @doc """
  An amount a person typed, in USDC, as base units: `{:ok, units}` for a
  positive amount with at most six decimals, else `:error`.

      iex> PatchbayWeb.OffersLive.Words.parse_usdc(" 5.5 ")
      {:ok, 5_500_000}
      iex> PatchbayWeb.OffersLive.Words.parse_usdc("1,000")
      {:ok, 1_000_000_000}
      iex> PatchbayWeb.OffersLive.Words.parse_usdc("0.0000001")
      :error
  """
  @spec parse_usdc(String.t()) :: {:ok, pos_integer()} | :error
  def parse_usdc(text) when is_binary(text) do
    text = text |> String.trim() |> String.replace(",", "")

    with true <- Regex.match?(~r/\A\d+(\.\d{1,6})?\z/, text),
         units = text |> Decimal.new() |> Decimal.mult(@unit) |> Decimal.to_integer(),
         true <- units > 0 do
      {:ok, units}
    else
      _invalid -> :error
    end
  end

  @doc """
  How long a lease has left at `now`, to the minute.

      iex> now = ~U[2026-11-13 12:00:00Z]
      iex> PatchbayWeb.OffersLive.Words.time_left(~U[2026-11-15 16:30:00Z], now)
      "2d 4h"
      iex> PatchbayWeb.OffersLive.Words.time_left(~U[2026-11-13 12:45:30Z], now)
      "45m"
  """
  @spec time_left(DateTime.t(), DateTime.t()) :: String.t()
  def time_left(ends_at, now) do
    minutes = max(DateTime.diff(ends_at, now), 0) |> div(60)

    cond do
      minutes >= 1440 -> "#{div(minutes, 1440)}d #{div(rem(minutes, 1440), 60)}h"
      minutes >= 60 -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m"
      true -> "Ending"
    end
  end

  @doc """
  Why Patchbay will not admit a purchase (`Patchbay.Offers.Admission.check/4`),
  as words and `{:address, wallet}` parts for `PatchbayWeb.OnchainSteps.note/1`.
  """
  @spec refusal(atom(), map(), map()) :: [String.t() | {:address, String.t()}]
  def refusal(:closed, _campaign, _placement), do: ["Buying is closed for now."]

  def refusal(:not_your_wallet, campaign, _placement),
    do: [{:address, campaign.advertiser}, " is no longer one of your wallets."]

  def refusal(:not_on_site, _campaign, %{source_origin: origin}),
    do: ["This campaign doesn't run on #{origin}."]

  def refusal(:blocked, campaign, _placement),
    do: ["Patchbay doesn't take offers from ", {:address, campaign.advertiser}, "."]

  def refusal(:not_accepted, campaign, _placement),
    do: ["Patchbay hasn't accepted ", {:address, campaign.advertiser}, " as an advertiser yet."]

  def refusal(:other_policy, _campaign, _placement),
    do: ["This placement takes offers on other terms."]

  def refusal(reason, _campaign, _placement)
      when reason in [:unknown_site, :unknown_placement, :unknown_slot, :not_your_campaign],
      do: ["This slot isn't open to your campaigns."]

  defp thousands(digits) do
    digits
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
