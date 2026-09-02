defmodule Patchbay.Patchbay.Changes.CaptureInvocationPreState do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &capture_pre_state/1)
  end

  defp capture_pre_state(changeset) do
    room =
      Patchbay.Patchbay.get_room_for_update!(Ash.Changeset.get_attribute(changeset, :room_id))

    pre_state = snapshot(room)

    # Both maps are cast to the same shape by the attribute's type, so the
    # caller's claim either is the locked state or it is not.
    case Ash.Changeset.get_argument(changeset, :pre_state) do
      nil ->
        capture(changeset, pre_state, room)

      ^pre_state ->
        capture(changeset, pre_state, room)

      _stale ->
        Ash.Changeset.add_error(
          changeset,
          field: :pre_state,
          message: "must match the locked room state at invocation start"
        )
    end
  end

  defp capture(changeset, pre_state, room) do
    arguments = Ash.Changeset.get_attribute(changeset, :arguments)

    changeset
    |> Ash.Changeset.force_change_attribute(:pre_state, pre_state)
    |> Ash.Changeset.force_change_attribute(:arguments_sha256, Digest.arguments_sha256(arguments))
    |> Ash.Changeset.force_change_attribute(
      :generation_key,
      Digest.generation_key(room.source_sha256, arguments)
    )
  end

  defp snapshot(room) do
    candidate_present =
      is_binary(room.candidate_markdown) and String.trim(room.candidate_markdown) != ""

    candidate_sha256 =
      if candidate_present do
        Digest.sha256(room.candidate_markdown)
      end

    %{
      ui_revision: room.ui_revision,
      source: %{present: true, sha256: room.source_sha256},
      candidate: %{present: candidate_present, sha256: candidate_sha256}
    }
  end
end
