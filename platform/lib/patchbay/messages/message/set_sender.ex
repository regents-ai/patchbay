defmodule Patchbay.Messages.Message.SetSender do
  @moduledoc """
  Makes the actor the message's sender: a signed-in person, or a paired agent
  with the person it is paired with. Nothing a caller sends can name the
  sender.
  """

  use Ash.Resource.Change

  alias Patchbay.Agents.Actor
  alias Patchbay.Identity.AgentProfile

  @impl true
  def change(changeset, _opts, %{actor: %AgentProfile{id: id}}),
    do: Ash.Changeset.force_change_attributes(changeset, person_profile_id: id)

  def change(changeset, _opts, %{actor: %Actor{} = agent}) do
    Ash.Changeset.force_change_attributes(changeset,
      person_profile_id: agent.beneficiary_profile_id,
      agent_profile_id: agent.id
    )
  end

  # Anyone else is refused by the action's policy.
  def change(changeset, _opts, _context), do: changeset
end
