defmodule Patchbay.Patchbay.Changes.ResetRoom do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Fixtures

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.change_attribute(:source_markdown, Fixtures.source_markdown())
    |> Ash.Changeset.change_attribute(
      :source_sha256,
      Patchbay.Patchbay.Digest.sha256(Fixtures.source_markdown())
    )
    |> Ash.Changeset.change_attribute(:candidate_markdown, nil)
    |> Ash.Changeset.change_attribute(:candidate_sha256, nil)
    |> Ash.Changeset.change_attribute(:ui_revision, 0)
    |> Ash.Changeset.change_attribute(:desired_tool_generation, 1)
    |> Ash.Changeset.change_attribute(:last_failed_invocation_id, nil)
    |> Ash.Changeset.change_attribute(:active_repair_proposal_id, nil)
    |> Ash.Changeset.change_attribute(:seed_version, Fixtures.seed_version())
    |> Ash.Changeset.change_attribute(:status, :ready)
  end
end
