defmodule Patchbay.Actors.Human do
  @moduledoc """
  A person signed in with Privy, named by their shared Regent account
  (`Patchbay.Identity.HumanAccount`), as the shared Points library reads them.
  """
  @enforce_keys [:human_account_id]
  defstruct [:human_account_id, role: :human]
end
