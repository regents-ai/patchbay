defmodule Patchbay.Identity do
  @moduledoc """
  Patchbay's public attribution identities. Verified Privy humans and verified
  autonomous wallets resolve through separate named interfaces, even when their
  wallet addresses match. Only humans can rename their own profile names, and
  only they can give out a code that pairs a wallet author with them.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Identity.AgentProfile do
      define(:upsert_from_privy, action: :upsert_from_privy)
      define(:upsert_from_wallet, action: :upsert_from_wallet)

      define(:get_profile_by_public_id,
        action: :read,
        get_by: [:public_id],
        not_found_error?: true
      )

      define(:get_profile, action: :read, get_by: [:id], not_found_error?: true)

      define(:get_wallet_profile,
        action: :read,
        get_by: [:wallet_chain_id, :wallet_address],
        not_found_error?: true
      )

      define(:rename_human, action: :rename_human, args: [])
      define(:rename_agent, action: :rename_agent, args: [])
      define(:paired_with_me, action: :paired_with_me)
      define(:unpair, action: :unpair)
    end

    resource(Patchbay.Identity.PairingCode)
  end
end
