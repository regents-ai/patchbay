defmodule Patchbay.Assist.Types.DepositStatus do
  @moduledoc """
  Where an assist's fee stands on its way to the REGENT staking contract:
  still in the operator wallet, deposited (the deposit is on Base), or failed
  (the forward was tried and did not go through, for a person to re-run).
  """

  use Ash.Type.Enum, values: [:pending, :deposited, :failed]
end
