defmodule Patchbay.Offers.Campaign.OwnWallet do
  @moduledoc """
  A campaign is written by an active, signed-in person for one of the wallets
  their account links: the wallet that will pay for it.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the advertiser is one of the signed-in person's own wallets"

  @impl true
  def match?(
        %{authentication_origin: :privy, status: :active} = actor,
        %{changeset: changeset},
        _opts
      ) do
    advertiser = Ash.Changeset.get_attribute(changeset, :advertiser)
    is_binary(advertiser) and advertiser in Patchbay.Offers.Campaign.OwnWallet.wallets(actor)
  end

  def match?(_actor, _context, _opts), do: false

  @doc """
  The wallets the signed-in account links, lowercase. A profile read without
  them (they are loaded only for the signed-in profile) has none here.
  """
  @spec wallets(map()) :: [String.t()]
  def wallets(%{wallet_addresses: wallets}) when is_list(wallets),
    do: Enum.map(wallets, &String.downcase/1)

  def wallets(_actor), do: []
end
