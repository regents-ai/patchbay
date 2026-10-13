defmodule Patchbay.Checks.Moderator do
  @moduledoc """
  Who may moderate Patchbay: a signed-in profile whose verified wallet is in
  this deployment's moderator allowlist. Moderators review Offers and answer
  every Credits help post.

  The check reads the wallet recorded on the signed-in profile, never an
  address a request sends. It depends on no other Patchbay module, so the
  resources whose policies name it do not recompile with the rest of the app.
  """

  use Ash.Policy.SimpleCheck

  @doc """
  The wallets allowed to moderate, from PATCHBAY_MODERATOR_WALLETS and the
  `:moderator_wallets` setting. A wallet here was verified when its holder
  signed in.
  """
  @spec moderator_wallets() :: [String.t()]
  def moderator_wallets do
    from_env =
      (System.get_env("PATCHBAY_MODERATOR_WALLETS") || "")
      |> String.split(",", trim: true)

    (from_env ++ List.wrap(Application.get_env(:patchbay, :moderator_wallets)))
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.uniq()
  end

  @doc "Whether the signed-in profile's verified wallet may moderate."
  @spec moderator?(term()) :: boolean()
  def moderator?(%{wallet_address: wallet}) when is_binary(wallet),
    do: String.downcase(wallet) in moderator_wallets()

  def moderator?(_profile), do: false

  @impl true
  def describe(_opts), do: "actor is a Patchbay moderator"

  @impl true
  def match?(actor, _context, _opts), do: moderator?(actor)
end
