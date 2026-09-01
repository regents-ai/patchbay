defmodule Patchbay.Patchbay.Changes.ApplyCandidate do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    candidate =
      Ash.Changeset.get_argument(changeset, :candidate_markdown) ||
        Ash.Changeset.get_attribute(changeset, :candidate_markdown)

    cond do
      not is_binary(candidate) or String.trim(candidate) == "" ->
        Ash.Changeset.add_error(changeset,
          field: :candidate_markdown,
          message: "must be present"
        )

      Digest.validate_artifact(candidate) == {:error, :artifact_too_large} ->
        Ash.Changeset.add_error(
          changeset,
          field: :candidate_markdown,
          message: "must be at most #{Digest.max_artifact_bytes()} UTF-8 bytes"
        )

      true ->
        Ash.Changeset.change_attribute(changeset, :candidate_sha256, Digest.sha256(candidate))
    end
  end
end
