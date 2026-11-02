defmodule Patchbay.Points.Accounts do
  @moduledoc """
  Read-only canonical account callbacks. Points knows an agent by its wallet,
  so an agent's name is the name of its person's latest pairing with that
  wallet.
  """
  @behaviour RegentPoints.Accounts

  @system %{role: :system}

  @impl true
  def human(id), do: Patchbay.Accounts.by_id!(id, actor: @system)

  @impl true
  def agent_names(_id, []), do: {:ok, %{}}

  def agent_names(id, wallets) do
    with {:ok, account} <- Patchbay.Accounts.by_id(id, actor: @system),
         {:ok, pairings} <- RegentAgents.pairing_histories(account.privy_user_id) do
      {:ok, pairings |> Enum.filter(&(&1.wallet in wallets)) |> Map.new(&{&1.wallet, &1.name})}
    end
  end
end
