defmodule Patchbay.Offers.Validations.OwnsVersion do
  @moduledoc "Keeps an action on an Offer wording to the advertiser who saved it."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: %{id: actor_id}}) do
    version_id = Ash.Changeset.get_attribute(changeset, :version_id)

    # Reads the version's owner to compare; it grants nothing.
    case Ash.get(Patchbay.Offers.CreativeVersion, version_id,
           load: [:creative],
           authorize?: false
         ) do
      {:ok, %{creative: %{owner_profile_id: ^actor_id}}} -> :ok
      _not_theirs -> {:error, field: :version_id, message: "is not one of your Offers"}
    end
  end

  def validate(_changeset, _opts, _context),
    do: {:error, field: :version_id, message: "is not one of your Offers"}
end
