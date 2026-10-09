defmodule Patchbay.Agents.RoomAccess do
  @moduledoc "Current delegation and product ownership, checked inside each room commit."
  alias Patchbay.Agents.Actor
  alias Patchbay.Patchbay.RoomEntrance

  def lock!(actor, room, invocation \\ nil)

  def lock!(%Actor{} = actor, room, invocation) do
    with {:ok, _} <-
           RegentAgents.Authority.lock(
             Patchbay.Repo,
             actor.pairing_id,
             actor.privy_user_id,
             actor.wallet_address
           ),
         {:ok, owner} when not is_nil(owner) <-
           Patchbay.Identity.get_profile(actor.beneficiary_profile_id),
         true <- owner.status == :active and owner.privy_user_id == actor.privy_user_id,
         true <- room.slug == RoomEntrance.personal_slug(owner),
         true <-
           is_nil(invocation) or
             (invocation.acting_agent_id == actor.id and invocation.pairing_id == actor.pairing_id) do
      :ok
    else
      _ -> raise Ash.Error.Forbidden, errors: []
    end
  end

  # Internal human flows cannot inherit an earlier agent's authority.
  def lock!(nil, _room, nil), do: :ok
  def lock!(nil, _room, %{pairing_id: nil}), do: :ok
  def lock!(_, _, _), do: raise(Ash.Error.Forbidden, errors: [])
end
