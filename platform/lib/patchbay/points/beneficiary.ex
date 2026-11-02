defmodule Patchbay.Points.Beneficiary do
  @moduledoc """
  Who an action earns Points for, from what the action kept when it was made:
  the person's Privy account, and the pairing when their agent acted. An
  agent earns for its person only while that pairing is in the person's own
  pairing history, as in the Regent template. An action with no person
  behind it, such as Patchbay's own answer, earns for nobody.
  """

  alias Patchbay.Accounts

  def of(nil, _pairing_id), do: {:error, :no_person}

  def of(privy_user_id, pairing_id) do
    case Accounts.by_privy(privy_user_id, actor: %{role: :system}) do
      {:ok, %{} = account} -> as(account, pairing_id)
      {:ok, nil} -> {:error, :account_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp as(account, nil),
    do:
      {:ok,
       %{
         account_id: account.id,
         actor_kind: "human",
         actor_id: to_string(account.id),
         evidence: %{}
       }}

  defp as(account, pairing_id) do
    case Patchbay.Points.Accounts.pairings(account.privy_user_id) do
      {:ok, pairings} -> agent(account, Enum.find(pairings, &(&1.id == pairing_id)))
      {:error, reason} -> {:retry, reason}
    end
  end

  defp agent(_account, nil), do: {:error, :agent_not_paired_with_person}

  defp agent(account, pairing),
    do:
      {:ok,
       %{
         account_id: account.id,
         actor_kind: "agent",
         # Points knows an agent by its wallet; the pairing is the proof it acted for this person.
         actor_id: pairing.wallet,
         evidence: %{"attribution_link_id" => pairing.id}
       }}
end
