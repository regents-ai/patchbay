defmodule Patchbay.Escrow.Signer do
  @moduledoc """
  The operator account that signs Patchbay's transactions on Base: its
  address, its key, the endpoint they are sent through and, for the escrow
  contract's calls, that contract's address. Inspecting it shows only the
  address, so an error or a report that carries it never carries the key.
  """

  @derive {Inspect, only: [:address]}
  @enforce_keys [:address, :private_key, :rpc_url]
  defstruct [:address, :private_key, :rpc_url, :contract_address]

  @type t :: %__MODULE__{
          address: String.t(),
          private_key: String.t(),
          rpc_url: String.t(),
          contract_address: String.t() | nil
        }
end
