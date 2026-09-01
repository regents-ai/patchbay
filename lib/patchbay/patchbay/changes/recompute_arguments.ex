defmodule Patchbay.Patchbay.Changes.RecomputeArguments do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    arguments =
      Ash.Changeset.get_argument(changeset, :arguments) ||
        Ash.Changeset.get_attribute(changeset, :arguments) || %{}

    pre_state =
      Ash.Changeset.get_argument(changeset, :pre_state) ||
        Ash.Changeset.get_attribute(changeset, :pre_state) || %{}

    source_sha256 = Map.get(pre_state, "source_sha256") || Map.get(pre_state, :source_sha256)

    changeset =
      Ash.Changeset.change_attribute(
        changeset,
        :arguments_sha256,
        Digest.arguments_sha256(arguments)
      )

    if is_binary(source_sha256) do
      Ash.Changeset.change_attribute(
        changeset,
        :generation_key,
        Digest.generation_key(source_sha256, arguments)
      )
    else
      changeset
    end
  end
end
