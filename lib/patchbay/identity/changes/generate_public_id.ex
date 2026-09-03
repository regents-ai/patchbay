defmodule Patchbay.Identity.Changes.GeneratePublicId do
  @moduledoc """
  Stamps the public name a profile is known by everywhere outside the database.

  The row's own key is what makes it, so a profile has exactly one public name
  for as long as it exists and nothing has to be checked to mint it. The key is
  read from the changeset when the action already carries one and generated
  here when it does not, so both halves are written from the same value.
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
      public_id: AgentProfile.public_id_for(id)
    })
  end
end
