defmodule Patchbay.Patchbay.Changes.RecomputeGeneratedCandidate do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument_or_change(changeset, :generated_candidate) do
      :error ->
        changeset

      {:ok, nil} ->
        Ash.Changeset.change_attribute(changeset, :generated_candidate_sha256, nil)

      {:ok, candidate} when is_binary(candidate) ->
        if Digest.validate_artifact(candidate) == :ok do
          Ash.Changeset.change_attribute(
            changeset,
            :generated_candidate_sha256,
            Digest.sha256(candidate)
          )
        else
          Ash.Changeset.add_error(changeset,
            field: :generated_candidate,
            message: "must be at most #{Digest.max_artifact_bytes()} UTF-8 bytes"
          )
        end

      {:ok, _candidate} ->
        Ash.Changeset.add_error(changeset,
          field: :generated_candidate,
          message: "must be a string"
        )
    end
  end
end
