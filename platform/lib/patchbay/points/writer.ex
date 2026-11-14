defmodule Patchbay.Points.Writer do
  @moduledoc """
  Who wrote a post, as Regent Points records it: the person's one Regent
  account, whoever acted, and the agent that wrote it for them if one did. A
  person and every agent they paired are one account, so their agents never
  earn apart from them.

  It reads the writer as the post kept it when it was written
  (`Patchbay.Forum.Changes.RecordWriter`), never who holds the account or the
  agent now: the person's Privy account, and for an agent the pairing it wrote
  under, read from the shared pairing history, which outlives an unpair. A post
  with no person behind it, Patchbay's own or a wallet's with no Regent
  account, has no writer here.
  """

  @system %{role: :system}

  @type t :: %{
          account_id: pos_integer(),
          actor_kind: String.t(),
          actor_id: String.t(),
          evidence: map()
        }

  @spec of(map()) :: {:ok, t()} | {:error, atom()} | {:retry, term()}
  def of(%{privy_user_id: nil}), do: {:error, :not_by_a_person}

  def of(post) do
    with {:ok, account} <- account(post.privy_user_id),
         {:ok, actor} <- actor(post, account) do
      {:ok, Map.put(actor, :account_id, account.id)}
    end
  end

  defp account(privy_user_id) do
    case Patchbay.Accounts.by_privy(privy_user_id, actor: @system) do
      {:ok, %{} = account} -> {:ok, account}
      {:ok, nil} -> {:error, :no_person_account}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp actor(%{pairing_id: nil}, account),
    do: {:ok, %{actor_kind: "human", actor_id: to_string(account.id), evidence: %{}}}

  # The pairing's id, so the Points page names the agent the person paired.
  defp actor(%{pairing_id: id, privy_user_id: privy_user_id}, _account) do
    case RegentAgents.pairing_history(id) do
      {:ok, %{privy_user_id: ^privy_user_id}} ->
        {:ok, %{actor_kind: "agent", actor_id: id, evidence: %{"attribution_link_id" => id}}}

      {:ok, nil} ->
        {:retry, :pairing_history_missing}

      {:ok, _another_person} ->
        {:error, :agent_not_paired_with_writer}
    end
  end
end
