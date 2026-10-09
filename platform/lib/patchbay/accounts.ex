defmodule Patchbay.Accounts do
  @moduledoc "The canonical Regent account, keyed only by server-verified Privy subject."
  use Ash.Domain

  resources do
    resource Patchbay.Accounts.HumanAccount do
      define(:by_privy, action: :by_privy, args: [:privy_user_id], not_found_error?: false)
      define(:by_id, action: :by_id, args: [:id], not_found_error?: false)
      define(:register_verified, action: :register_verified)
      define(:refresh_verified, action: :refresh_verified)
    end
  end

  def establish(%RegentPrivy.Session{} = verified) do
    attrs = Map.take(verified, [:privy_user_id, :wallet_address, :wallet_addresses])

    with {:ok, account} <- register_verified(attrs, actor: %{role: :system}),
         do: refresh_verified(account, Map.delete(attrs, :privy_user_id), actor: %{role: :system})
  end
end
