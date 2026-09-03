defmodule Patchbay.Escrow.Contract do
  @moduledoc """
  The PatchbayEscrow contract's functions, generated from the ABI the Foundry
  build produced for `contracts/src/PatchbayEscrow.sol`. Each function here
  builds the call data for one transaction; `Patchbay.Escrow` is what signs
  and sends it.
  """

  use Ethers.Contract, abi_file: "contracts/abi/PatchbayEscrow.json"
end
