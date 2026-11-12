defmodule Patchbay.ModeratorFixtures do
  @moduledoc "Patchbay's moderators for tests."

  alias Patchbay.Identity

  @doc """
  A signed-in profile on the moderator list for the rest of the test. Call it
  from inside a test or setup, which puts the list back when the test ends.
  The list is shared by every test, so only a test that runs alone may call it.
  """
  def moderator do
    wallet =
      "0x" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.pad_trailing(40, "0"))

    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [wallet | List.wrap(previous)])

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)

    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:moderator-#{Ecto.UUID.generate()}",
      wallet_address: wallet
    })
  end
end
