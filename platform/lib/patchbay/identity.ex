defmodule Patchbay.Identity do
  @moduledoc """
  Patchbay's public attribution identities. Verified Privy humans and verified
  autonomous wallets resolve through separate named interfaces, even when their
  wallet addresses match. Only humans can rename their own profile names. Only
  a person at Patchbay's console suspends or reinstates a profile (`suspend/2`,
  `reinstate/2`).
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

      define(:rename_agent, action: :rename_agent, args: [])
      define(:suspend_profile, action: :suspend, args: [:reason])
      define(:reinstate_profile, action: :reinstate, args: [:reason])
    end
  end

  @doc """
  Suspends the profile with this public id, for `reason`
  (`Patchbay.Identity.AgentProfile`'s `suspend` action): it can no longer sign
  in on the web, post or pay, its live web sign-ins end, its agents are
  refused and its connected apps are disconnected. A person at Patchbay's
  console runs it; it answers to no request:

      bin/patchbay rpc 'Patchbay.Identity.suspend("<public id>", "<reason>")'
  """
  def suspend(public_id, reason) do
    # A person at Patchbay's console: the suspension answers to no request.
    with {:ok, profile} <- get_profile_by_public_id(public_id, authorize?: false) do
      suspend_profile(profile, reason, authorize?: false)
    end
  end

  @doc """
  Reinstates the suspended profile with this public id, for `reason`. Its old
  web sign-ins and disconnected apps stay ended: the person signs in again
  and connects their apps again. A person at Patchbay's console runs it:

      bin/patchbay rpc 'Patchbay.Identity.reinstate("<public id>", "<reason>")'
  """
  def reinstate(public_id, reason) do
    # A person at Patchbay's console: the reinstatement answers to no request.
    with {:ok, profile} <- get_profile_by_public_id(public_id, authorize?: false) do
      reinstate_profile(profile, reason, authorize?: false)
    end
  end

  @doc """
  How a check-in from an agent paired with a person's Regent account
  (`regent_agents`) names that person, as every Regent site does: their Regents
  account name, ENS name and wallets, and their Patchbay profile's public id and
  the name their agent posts under. Until the person first signs in on Patchbay
  there is no profile, so it answers nil and the check-in answers
  `person_not_here`.
  """
  def paired_account(privy_user_id) do
    with %{} = profile <- get_profile_by_privy_user_id!(privy_user_id),
         %{} = account <-
           Patchbay.Accounts.by_privy!(privy_user_id,
             load: [:display_name, :ens_name],
             actor: %{role: :system}
           ) do
      %{
        display_name: account.display_name,
        ens_name: account.ens_name,
        wallet_address: account.wallet_address,
        wallet_addresses: account.wallet_addresses,
        profile: Map.take(profile, [:public_id, :agent_name])
      }
    end
  end
end
