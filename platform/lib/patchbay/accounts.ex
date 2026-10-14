defmodule Patchbay.Accounts do
  @moduledoc """
  The canonical Regent account, keyed only by server-verified Privy subject,
  and the ENS name and picture of its wallet.
  """
  use Ash.Domain

  alias Patchbay.Accounts.EnsIdentity

  resources do
    resource Patchbay.Accounts.HumanAccount do
      define(:by_privy, action: :by_privy, args: [:privy_user_id], not_found_error?: false)
      define(:by_id, action: :by_id, args: [:id], not_found_error?: false)
      define(:register_verified, action: :register_verified)
      define(:refresh_verified, action: :refresh_verified)
    end

    resource EnsIdentity do
      define(:request_ens_lookup,
        action: :request_lookup,
        args: [:human_account_id, :wallet_address]
      )
    end
  end

  @actor %{role: :system}

  def establish(%RegentPrivy.Session{} = verified) do
    attrs = Map.take(verified, [:privy_user_id, :wallet_address, :wallet_addresses])

    with {:ok, account} <- register_verified(attrs, actor: @actor),
         {:ok, account} <-
           refresh_verified(account, Map.delete(attrs, :privy_user_id), actor: @actor),
         :ok <- request_ens_lookup(account),
         do: {:ok, account}
  end

  defp request_ens_lookup(account) do
    if EnsIdentity.looking_up?() do
      with {:ok, _identity} <-
             request_ens_lookup(account.id, account.wallet_address, actor: @actor),
           do: :ok
    else
      :ok
    end
  end
end
