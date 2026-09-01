defmodule Patchbay.Patchbay.Changes.RecomputeDigest do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, opts, _context) do
    source_attribute = Keyword.fetch!(opts, :source_attribute)
    digest_attribute = Keyword.fetch!(opts, :digest_attribute)

    value =
      Ash.Changeset.get_argument(changeset, source_attribute) ||
        Ash.Changeset.get_attribute(changeset, source_attribute)

    if is_binary(value) do
      case Digest.validate_artifact(value) do
        :ok ->
          Ash.Changeset.change_attribute(changeset, digest_attribute, Digest.sha256(value))

        {:error, :artifact_too_large} ->
          Ash.Changeset.add_error(
            changeset,
            field: source_attribute,
            message: "must be at most #{Digest.max_artifact_bytes()} UTF-8 bytes"
          )
      end
    else
      changeset
    end
  end
end
