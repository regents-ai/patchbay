defmodule Patchbay.Points.AccountActivated do
  @moduledoc """
  Regent Points' check of a new account: it reads the saved account and answers
  with what Points records. The account was activated when it was created.
  As ash-template's `AshTemplate.Points.AccountActivated`.

  The shared account table keeps that time to the second, rounded, so for up
  to half a second after the sign-in it can be ahead of the clock; the check
  then runs again later rather than turning the award down.
  """

  @system %{role: :system}

  def verify(%{"source_event_key" => id}) do
    case Patchbay.Accounts.by_id(String.to_integer(id), actor: @system) do
      {:ok, %{} = account} -> created(account)
      {:ok, nil} -> {:error, :account_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp created(account) do
    if DateTime.after?(account.created_at, DateTime.utc_now()),
      do: {:retry, :account_created_ahead_of_clock},
      else: {:ok, facts(account)}
  end

  defp facts(account) do
    id = to_string(account.id)

    %{
      # The same source as Patchbay.Points.Award: one Regents account on every site.
      source_app: "regents",
      source_kind: "account",
      source_event_key: id,
      account_id: account.id,
      actor_kind: "human",
      actor_id: id,
      source_action_at: account.created_at,
      qualified_at: account.created_at,
      evidence_ref: "account:" <> id,
      evidence: %{}
    }
  end
end
