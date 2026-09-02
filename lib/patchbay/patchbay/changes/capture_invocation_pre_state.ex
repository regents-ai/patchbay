defmodule Patchbay.Patchbay.Changes.CaptureInvocationPreState do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.{CanonicalJSON, Digest}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &capture_pre_state/1)
  end

  defp capture_pre_state(changeset) do
    room =
      Patchbay.Patchbay.get_room_for_update!(Ash.Changeset.get_attribute(changeset, :room_id))

    pre_state = snapshot(room)

    case supplied_pre_state(changeset) do
      :missing ->
        capture(changeset, pre_state, room)

      {:supplied, nil} ->
        capture(changeset, pre_state, room)

      {:supplied, supplied_pre_state} ->
        if same_state?(supplied_pre_state, pre_state) do
          capture(changeset, pre_state, room)
        else
          Ash.Changeset.add_error(
            changeset,
            field: :pre_state,
            message: "must match the locked room state at invocation start"
          )
        end
    end
  end

  defp capture(changeset, pre_state, room) do
    arguments =
      Ash.Changeset.get_argument(changeset, :arguments) ||
        Ash.Changeset.get_attribute(changeset, :arguments) || %{}

    changeset
    |> Ash.Changeset.force_change_attribute(:pre_state, pre_state)
    |> Ash.Changeset.force_change_attribute(:arguments_sha256, Digest.arguments_sha256(arguments))
    |> Ash.Changeset.force_change_attribute(
      :generation_key,
      Digest.generation_key(room.source_sha256, arguments)
    )
  end

  defp supplied_pre_state(changeset) do
    params = Map.get(changeset, :params, %{})

    case Map.fetch(params, :pre_state) do
      {:ok, value} ->
        {:supplied, value}

      :error ->
        case Map.fetch(params, "pre_state") do
          {:ok, value} -> {:supplied, value}
          :error -> :missing
        end
    end
  end

  defp snapshot(room) do
    candidate_present =
      is_binary(room.candidate_markdown) and String.trim(room.candidate_markdown) != ""

    candidate_sha256 =
      if candidate_present do
        Digest.sha256(room.candidate_markdown)
      end

    %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{"present" => candidate_present, "sha256" => candidate_sha256}
    }
  end

  defp same_state?(left, right) when is_map(left) and is_map(right) do
    CanonicalJSON.encode(left) == CanonicalJSON.encode(right)
  rescue
    ArgumentError -> false
  end

  defp same_state?(_left, _right), do: false
end
