defmodule Patchbay.Points.Accounts do
  @moduledoc "Read-only canonical account callbacks; Points activation stays disabled."
  @behaviour RegentPoints.Accounts

  # Points answer only at patchbay.help, so a person shows by their ENS name or
  # account name in the site's `:name_first` order, as `AgentProfile.own_name/2`.
  @name_fields (case Application.compile_env!(:patchbay, :name_first) do
                  :chosen -> [:display_name, :ens_name]
                  :ens -> [:ens_name, :display_name]
                end)

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

  # What the board shows of each account. `name` is the account name when that
  # is the name it shows, else nil: the board then draws its ENS name or short
  # wallet with the copy icon. Patchbay draws its own faces, so `squares` is nil.
  @impl true
  def people([]), do: {:ok, %{}}

  def people(ids) do
    with {:ok, accounts} <- Patchbay.Accounts.by_ids(ids, actor: %{role: :system}) do
      {:ok,
       Map.new(accounts, fn account ->
         wallet = present(account.wallet_address)

         {account.id,
          %{
            name: listed_name(account, wallet),
            wallet: wallet,
            ens_name: present(account.ens_name),
            squares: nil,
            picture: present(account.ens_avatar_url)
          }}
       end)}
    end
  end

  defp listed_name(account, wallet) do
    case Enum.find(@name_fields, &present(Map.get(account, &1))) do
      :display_name -> present(account.display_name)
      _shown_by_wallet when is_nil(wallet) -> "Account"
      _shown_by_wallet -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil
end
