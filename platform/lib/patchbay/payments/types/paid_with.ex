defmodule Patchbay.Payments.Types.PaidWith do
  @moduledoc """
  How a payment intent was paid: USDC on Base, signed over x402, or the
  payer's Patchbay Credits bought by card.
  """

  use Ash.Type.Enum, values: [:usdc, :credits]
end
