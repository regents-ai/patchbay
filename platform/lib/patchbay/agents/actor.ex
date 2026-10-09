defmodule Patchbay.Agents.Actor do
  @moduledoc "A verified agent keeps its own public author and its current account delegation."
  @enforce_keys [:id, :wallet_address, :privy_user_id, :pairing_id, :beneficiary_profile_id]
  defstruct [
    :id,
    :wallet_address,
    :privy_user_id,
    :pairing_id,
    :beneficiary_profile_id,
    :human_account_id,
    :acting_agent_id,
    :principals,
    authentication_origin: :wallet,
    role: :agent
  ]

  def new(profile, beneficiary, account, pairing) do
    %__MODULE__{
      id: profile.id,
      acting_agent_id: profile.id,
      wallet_address: profile.wallet_address,
      privy_user_id: pairing.privy_user_id,
      pairing_id: pairing.id,
      beneficiary_profile_id: beneficiary.id,
      human_account_id: account.id,
      principals: [Patchbay.Forum.Principal.for_profile(beneficiary.id)]
    }
  end
end
