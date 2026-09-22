defmodule Patchbay.Assist.Staking do
  @moduledoc """
  The one function of the REGENT revenue staking contract an assist's fee is
  handed to, `depositUSDC(amount, sourceTag, sourceRef)`, from the interface
  the Autolaunch contracts pin (`IRegentRevenueStakingMinimal`, produced with
  `forge inspect`). It builds the call data; `Patchbay.Assist.Forward` signs
  and sends it.
  """

  use Ethers.Contract, abi_file: "../contracts/abi/RegentRevenueStakingMinimal.json"
end
