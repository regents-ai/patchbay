defmodule Patchbay.Points.Accounts do
  @moduledoc "Read-only canonical account callbacks; Points activation stays disabled."
  @behaviour RegentPoints.Accounts

  @impl true
  def human(id), do: Patchbay.Accounts.by_id!(id, actor: %{role: :system})

  @impl true
  def agent_names(_id, []), do: {:ok, %{}}

  def agent_names(id, ids) do
    with {:ok, account} <- Patchbay.Accounts.by_id(id, actor: %{role: :system}),
         {:ok, %{rows: rows}} <-
           Ecto.Adapters.SQL.query(
             Patchbay.Repo,
             "SELECT id::text, name FROM regent_agents.pairing_history WHERE privy_user_id = $1 AND id::text = ANY($2::text[])",
             [account.privy_user_id, ids]
           ) do
      {:ok, Map.new(rows, fn [id, name] -> {id, name} end)}
    end
  end
end
