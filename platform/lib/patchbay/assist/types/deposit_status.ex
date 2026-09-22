defmodule Patchbay.Assist.Types.DepositStatus do
  @moduledoc """
  Where an assist's fee stands on its way to the REGENT staking contract:
  still in the operator wallet, deposited (the deposit is on Base), failed
  (the forward was tried and did not go through, for a person to re-run),
  no fee at all, for a free fix, or paid from Patchbay Credits bought by
  card, whose money is in Stripe and never reaches the operator wallet.
  """

  use Ash.Type.Enum, values: [:pending, :deposited, :failed, :no_fee, :card]
end
