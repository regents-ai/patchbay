defmodule Patchbay.Offers.Validations.WordingOfText do
  @moduledoc "Keeps a block of some words to a wording that has those words."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    text_sha256 = changeset.data.text_sha256

    # Reads the wording's words to compare; it grants nothing.
    case Ash.get(Patchbay.Offers.CreativeVersion, version_id, authorize?: false) do
      {:ok, %{text_sha256: ^text_sha256}} -> :ok
      _other -> {:error, field: :version_id, message: "does not have these words"}
    end
  end
end
