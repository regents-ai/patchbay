defmodule Patchbay.Identity do
  @moduledoc """
  Patchbay's public attribution identities. Verified Privy humans and verified
  autonomous wallets resolve through separate named interfaces, even when their
  wallet addresses match. Only humans can rename their own profile names.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Identity.AgentProfile do
      define(:upsert_from_privy, action: :upsert_from_privy)
      define(:upsert_from_wallet, action: :upsert_from_wallet)
      define(:record_backing, action: :record_backing, args: [:human_id, :agent_count])

      define(:get_profile_by_public_id,
        action: :read,
        get_by: [:public_id],
        not_found_error?: true
      )

      define(:get_profile, action: :read, get_by: [:id], not_found_error?: true)

      define(:get_profile_by_privy_user_id,
        action: :read,
        get_by: [:privy_user_id],
        not_found_error?: false
      )

      define(:get_wallet_profile,
        action: :read,
        get_by: [:wallet_chain_id, :wallet_address],
        not_found_error?: true
      )

      define(:rename_human, action: :rename_human, args: [])
      define(:rename_agent, action: :rename_agent, args: [])
    end
  end

  @doc """
  How a check-in from an agent paired with a person's Regent account
  (`regent_agents`) names that person's Patchbay profile: its public id and the
  two names it posts under. Until the person first signs in on Patchbay there is
  no profile, so it answers nil and the check-in answers `person_not_here`.
  """
  def paired_account(privy_user_id) do
    case get_profile_by_privy_user_id!(privy_user_id) do
      nil -> nil
      profile -> %{profile: Map.take(profile, [:public_id, :human_name, :agent_name])}
    end
  end
end
