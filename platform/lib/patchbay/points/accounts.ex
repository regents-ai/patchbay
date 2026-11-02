defmodule Patchbay.Points.Accounts do
  @moduledoc """
  Read-only canonical account callbacks, and the agents a person has paired.
  Points knows an agent by its wallet, so an agent's name is the name of its
  latest pairing with that wallet.
  """
  @behaviour RegentPoints.Accounts

  @system %{role: :system}

  @impl true
  def human(id), do: Patchbay.Accounts.by_id!(id, actor: @system)

  @impl true
  def agent_names(_id, []), do: {:ok, %{}}

  def agent_names(id, wallets) do
    with {:ok, account} <- Patchbay.Accounts.by_id(id, actor: @system),
         {:ok, pairings} <- pairings(account.privy_user_id) do
      {:ok, pairings |> Enum.filter(&(&1.wallet in wallets)) |> Map.new(&{&1.wallet, &1.name})}
    end
  end

  @doc "Every agent `privy_user_id` has paired, ended pairings too, oldest first."
  def pairings(privy_user_id) do
    with {:ok, %{rows: rows}} <-
           Ecto.Adapters.SQL.query(
             Patchbay.Repo,
             "SELECT id::text, wallet, name FROM regent_agents.pairing_history WHERE privy_user_id = $1 ORDER BY paired_at",
             [privy_user_id]
           ) do
      {:ok, Enum.map(rows, fn [id, wallet, name] -> %{id: id, wallet: wallet, name: name} end)}
    end
  end
end
