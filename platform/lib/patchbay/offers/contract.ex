defmodule Patchbay.Offers.Contract do
  @moduledoc """
  The AgentOfferMarket contract's functions and events, generated from the ABI
  the Foundry build produced for `contracts/src/AgentOfferMarket.sol`
  (`forge inspect AgentOfferMarket abi --json`). Each function builds the call
  data for one read or one transaction; `Patchbay.Offers.Market` reads with
  them and the offers page's buttons send them.
  """

  use Ethers.Contract, abi_file: "../contracts/abi/AgentOfferMarket.json"
end
