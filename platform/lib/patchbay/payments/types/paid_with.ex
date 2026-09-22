defmodule Patchbay.Payments.Types.PaidWith do
  @moduledoc """
  How a payment intent was paid: USDC on Base, signed over x402, or the
  payer's Patchbay Credits bought by card. A paid priority report's bounty is
  held the way it was paid: USDC in the escrow contract on Base, credits on
  Patchbay's own ledger.
  """

  use Ash.Type.Enum, values: [:usdc, :credits]

  @doc "The name an answer gives it."
  @spec written(:usdc | :credits) :: String.t()
  def written(:usdc), do: "usdc"
  def written(:credits), do: "patchbay_credits"
end
