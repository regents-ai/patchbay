defmodule Patchbay.OAuth.EventAccess do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  def describe(_), do: "has live event authority and owns this account's client subscription"

  def match?(%Patchbay.OAuth.Actor{} = actor, %{changeset: changeset}, _) do
    Patchbay.OAuth.Actor.live?(actor) and
      owner(changeset) in actor.principals and
      case changeset.action.type do
        :create -> Ash.Changeset.get_attribute(changeset, :oauth_client_id) == actor.client_id
        _ -> changeset.data.oauth_client_id == actor.client_id
      end
  end

  def match?(%Patchbay.Agents.Actor{} = actor, %{changeset: changeset} = context, _) do
    RegentAgents.Checks.Paired.match?(actor, context, repo: Patchbay.Repo) and
      owner(changeset) in actor.principals and
      case changeset.action.type do
        :create -> is_nil(Ash.Changeset.get_attribute(changeset, :oauth_client_id))
        _ -> is_nil(changeset.data.oauth_client_id)
      end
  end

  def match?(_, _, _), do: false

  defp owner(%{action: %{type: :create}} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :owner_id)

  defp owner(changeset), do: changeset.data.owner_id
end
