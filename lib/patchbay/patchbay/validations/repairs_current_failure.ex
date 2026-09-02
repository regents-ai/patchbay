defmodule Patchbay.Patchbay.Validations.RepairsCurrentFailure do
  @moduledoc """
  A repair may only be approved while it still answers the failure it was built
  from: the room's latest verified failure, run against the source the room
  still holds, with the candidate the canary actually measured.

  Everything the rule compares lives on another record, so it reads the source
  call and the room it belongs to rather than trusting what the proposal
  recorded when it was written.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.Digest

  @invocation_fields [
    :id,
    :arguments,
    :pre_state,
    :effective_status,
    :generated_candidate_sha256,
    :generation_key
  ]

  @room_fields [:id, :source_sha256, :last_failed_invocation_id]

  @impl true
  def validate(changeset, _opts, _context) do
    proposal = changeset.data

    invocation =
      Domain.get_invocation!(proposal.source_invocation_id, query: [select: @invocation_fields])

    room = Domain.get_room_by_id!(proposal.room_id, query: [select: @room_fields])

    still_current(proposal, room, invocation)
  end

  @impl true
  def describe(_opts), do: "repair must still answer the room's current verified failure"

  defp still_current(proposal, room, invocation) do
    cond do
      room.last_failed_invocation_id != invocation.id ->
        stale(:source_invocation_id, "the room has moved on from this failed call")

      invocation.effective_status != :verified_failure ->
        stale(:source_invocation_id, "the source call is not a persisted verified failure")

      get_in(invocation.pre_state, ["source", "sha256"]) != room.source_sha256 ->
        stale(:input_sha256, "the source changed after the failed call")

      Digest.generation_key(room.source_sha256, invocation.arguments) != invocation.generation_key ->
        stale(:input_sha256, "the failed call no longer matches the room's source and arguments")

      invocation.generation_key != proposal.input_sha256 ->
        stale(:input_sha256, "this repair was built from different input than the failed call")

      recorded_candidate_digest(proposal) != invocation.generated_candidate_sha256 ->
        stale(:canary_result, "the recorded candidate digest no longer matches the failed call")

      true ->
        :ok
    end
  end

  defp recorded_candidate_digest(proposal),
    do: Map.get(proposal.canary_result, "candidate_sha256")

  defp stale(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
