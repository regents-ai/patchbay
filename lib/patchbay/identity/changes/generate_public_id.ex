defmodule Patchbay.Identity.Changes.GeneratePublicId do
  @moduledoc """
  Stamps the public name a profile is known by everywhere outside the database,
  and the two placeholder names it starts life with.

  The row's own key is what makes all three, so a profile has exactly one
  public name for as long as it exists, its first two chosen names cannot
  collide with anyone else's, and nothing has to be checked to mint them. The
  key is read from the changeset when the action already carries one and
  generated here when it does not, so every part is written from the same
  value.

  The two names are placeholders on purpose. They are the only thing about a
  profile its owner is invited to change, from their own page or, for the agent
  half, from a tool.
  """

  use Ash.Resource.Change

  alias Patchbay.Identity.AgentProfile

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &stamp/1)
  end

  defp stamp(changeset) do
    id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

    Ash.Changeset.force_change_attributes(changeset, %{
      id: id,
      public_id: AgentProfile.public_id_for(id),
      agent_name: AgentProfile.starting_name(id, "agent"),
      human_name: AgentProfile.starting_name(id, "human")
    })
  end
end
