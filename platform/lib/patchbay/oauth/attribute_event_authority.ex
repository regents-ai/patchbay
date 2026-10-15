defmodule Patchbay.OAuth.AttributeEventAuthority do
  @moduledoc false
  use Ash.Resource.Change

  def change(changeset, _opts, %{actor: %Patchbay.OAuth.Actor{} = actor}) do
    changeset
    |> Ash.Changeset.force_change_attributes(%{
      oauth_token_id: actor.token_id,
      oauth_client_id: actor.client_id,
      beneficiary_profile_id: actor.beneficiary_profile_id,
      acting_agent_id: nil,
      human_account_id: nil,
      pairing_id: nil
    })
    |> Ash.Changeset.before_action(fn changeset ->
      expiry = Ash.Changeset.get_attribute(changeset, :expires_at)

      if Patchbay.OAuth.Actor.live?(actor) and
           DateTime.compare(expiry, actor.expires_at) != :gt,
         do: changeset,
         else: Ash.Changeset.add_error(changeset, "live OAuth event authority required")
    end)
  end

  def change(changeset, _opts, %{actor: %Patchbay.Agents.Actor{}} = context) do
    changeset
    |> RegentAgents.RequirePairing.change([repo: Patchbay.Repo], context)
    |> Patchbay.Agents.AttributeAction.change([], context)
    |> Ash.Changeset.force_change_attributes(%{oauth_token_id: nil, oauth_client_id: nil})
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, "event authority required")
end
