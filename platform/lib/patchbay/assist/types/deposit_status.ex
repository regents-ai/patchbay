defmodule Patchbay.Assist.Types.DepositStatus do
  @moduledoc """
  Where an assist's fee stands on its way to the REGENT staking contract:
  still in the operator wallet, being forwarded (its forward was taken and
  may have reached Base), deposited (the deposit is on Base), failed (the
  forward did not go through, for a person to look at), or no fee at all,
  for a free fix.
  """

  use Ash.Type.Enum, values: [:pending, :forwarding, :deposited, :failed, :no_fee]
end
