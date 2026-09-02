defmodule Patchbay.Patchbay.RepairApprovalService do
  @moduledoc """
  The approval and publication boundary for a repair proposal.

  Two callers reach it, and both name themselves: the owner's control on the
  page, and Patchbay's own worker acting on a report it verified against its
  record. No tool a browser agent can call reaches this service, and nothing a
  caller sends can stand in for the name it approves under. All freshness checks
  happen after locking the room, immediately before approval and hot-swap.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    CanaryRunner,
    Digest,
    Invocation,
    RepairProposal,
    Room,
    RoomTimeline,
    ToolPublisher,
    ToolRevision
  }

  @spec approve_and_publish!(RepairProposal.t() | binary(), binary(), keyword()) ::
          RepairProposal.t()
  def approve_and_publish!(proposal_or_id, approved_by, opts \\ [])

  def approve_and_publish!(proposal_or_id, approved_by, opts) when is_binary(approved_by) do
    if String.trim(approved_by) == "", do: raise(ArgumentError, "human approver is required")

    proposal = load_proposal!(proposal_or_id)

    [Room, RepairProposal, ToolRevision, Invocation]
    |> Ash.transact(
      fn -> approve_locked!(proposal.id, approved_by) end,
      Keyword.take(opts, [:timeout])
    )
    |> unwrap!()
  end

  def approve_and_publish!(_proposal, _approved_by, _opts),
    do: raise(ArgumentError, "human approver is required")

  @spec reject!(RepairProposal.t() | binary(), keyword()) :: RepairProposal.t()
  def reject!(proposal_or_id, opts \\ []) do
    proposal = load_proposal!(proposal_or_id)

    [Room, RepairProposal, ToolRevision]
    |> Ash.transact(fn -> reject_locked!(proposal.id) end, Keyword.take(opts, [:timeout]))
    |> unwrap!()
  end

  defp approve_locked!(proposal_id, approved_by) do
    proposal = Domain.get_repair_proposal_for_update!(proposal_id)
    room = Domain.get_room_for_update!(proposal.room_id)
    source_invocation = Domain.get_invocation_for_update!(proposal.source_invocation_id)
    source_revision = Domain.get_tool_revision_for_update!(proposal.source_tool_revision_id)
    candidate_revision = lock_candidate_revision!(proposal)

    validate_fresh!(proposal, room, source_invocation, source_revision, candidate_revision)

    proposal = Domain.approve_repair_proposal!(proposal, approved_by)
    Domain.mark_tool_revision_approved!(candidate_revision)
    Domain.begin_publication!(room)

    RoomTimeline.append!(room, :approval_granted, %{
      "proposal_id" => proposal.id,
      "approved_by" => approved_by
    })

    published_revision = ToolPublisher.publish!(candidate_revision)
    proposal = Domain.publish_repair_proposal!(proposal)
    room = Domain.get_room_by_id!(room.id)
    Domain.mark_repaired!(room)

    RoomTimeline.append!(room, :publication_requested, %{
      "proposal_id" => proposal.id,
      "revision_id" => published_revision.id
    })

    proposal
  end

  defp reject_locked!(proposal_id) do
    proposal = Domain.get_repair_proposal_for_update!(proposal_id)
    room = Domain.get_room_for_update!(proposal.room_id)
    candidate_revision = lock_candidate_revision!(proposal)

    if proposal.status != :ready_for_approval do
      raise ArgumentError, "proposal is not ready for rejection"
    end

    proposal = Domain.reject_repair_proposal!(proposal)
    Domain.retire_tool_revision!(candidate_revision)

    room = Domain.set_active_repair_proposal!(room, private_arguments: %{proposal_id: nil})
    _room = Domain.record_failure!(room, room.last_failed_invocation_id)

    RoomTimeline.append!(room, :approval_rejected, %{"proposal_id" => proposal.id})

    proposal
  end

  defp unwrap!({:ok, proposal}), do: proposal
  defp unwrap!({:error, error}), do: raise(Ash.Error.to_error_class(error))

  # Every branch below is a freshness check against the locked rows, in the
  # order a stale approval would fail them: the proposal, then the invocation
  # it came from, then the digests, then the candidate revision, then the
  # canary re-run.
  defp validate_fresh!(proposal, room, invocation, source_revision, candidate_revision) do
    validate_candidate_evidence!(proposal, invocation)
    validate_invocation_current!(room, invocation, source_revision)
    validate_digests!(proposal, room, invocation)
    validate_candidate_revision!(proposal, room, invocation, source_revision, candidate_revision)
    validate_canary!(room, invocation, candidate_revision)
  end

  defp validate_candidate_evidence!(proposal, invocation) do
    cond do
      proposal.status != :ready_for_approval ->
        raise ArgumentError, "proposal is not ready for approval"

      invocation.effective_status != :verified_failure ->
        raise ArgumentError, "source invocation is not a persisted verified failure"

      not is_binary(invocation.generated_candidate) or
          String.trim(invocation.generated_candidate) == "" ->
        raise ArgumentError, "source invocation has no generated candidate"

      not is_binary(invocation.generated_candidate_sha256) or
          Digest.sha256(invocation.generated_candidate) != invocation.generated_candidate_sha256 ->
        raise ArgumentError, "source invocation candidate digest is invalid"

      true ->
        :ok
    end
  end

  defp validate_invocation_current!(room, invocation, source_revision) do
    cond do
      room.last_failed_invocation_id != invocation.id ->
        raise ArgumentError, "source invocation is stale"

      invocation.room_id != room.id or source_revision.room_id != room.id ->
        raise ArgumentError, "proposal relationships are stale"

      source_revision.status != :desired ->
        raise ArgumentError, "source tool revision is stale"

      room.desired_tool_generation != source_revision.generation ->
        raise ArgumentError, "desired tool revision is stale"

      true ->
        :ok
    end
  end

  defp validate_digests!(proposal, room, invocation) do
    cond do
      source_state_digest(invocation) != room.source_sha256 ->
        raise ArgumentError, "source state changed since the failed invocation"

      Digest.generation_key(room.source_sha256, invocation.arguments) != invocation.generation_key ->
        raise ArgumentError, "source invocation generation key is stale"

      invocation.generation_key != proposal.input_sha256 ->
        raise ArgumentError, "proposal input digest is stale"

      true ->
        :ok
    end
  end

  defp validate_candidate_revision!(
         proposal,
         room,
         invocation,
         source_revision,
         candidate_revision
       ) do
    cond do
      candidate_revision.room_id != room.id ->
        raise ArgumentError, "candidate tool revision is stale"

      candidate_revision.parent_revision_id != source_revision.id ->
        raise ArgumentError, "candidate parent revision is stale"

      candidate_revision.generation != source_revision.generation + 1 ->
        raise ArgumentError, "candidate generation is invalid"

      candidate_revision.status not in [:canary_passed, :ready_for_approval, :approved] ->
        raise ArgumentError, "candidate revision is not canary-approved"

      canary_candidate_digest(proposal) not in [nil, invocation.generated_candidate_sha256] ->
        raise ArgumentError, "proposal candidate digest is stale"

      Digest.contract_sha256(candidate_revision) != candidate_revision.contract_sha256 ->
        raise ArgumentError, "candidate contract digest is invalid"

      true ->
        :ok
    end
  end

  defp validate_canary!(room, invocation, candidate_revision) do
    canary =
      CanaryRunner.run(room.source_markdown, invocation.generated_candidate, candidate_revision)

    if canary.passed != true or
         canary.candidate_sha256 != invocation.generated_candidate_sha256 do
      raise ArgumentError, "candidate canary has not passed"
    end

    canary
  end

  defp source_state_digest(invocation) do
    get_in(invocation.pre_state, ["source", "sha256"]) ||
      get_in(invocation.pre_state, [:source, :sha256])
  end

  defp canary_candidate_digest(proposal) do
    canary = proposal.canary_result || %{}
    get_in(canary, ["candidate_sha256"]) || get_in(canary, [:candidate_sha256])
  end

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: nil}),
    do: raise(ArgumentError, "proposal has no candidate revision")

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: id}),
    do: Domain.get_tool_revision_for_update!(id)

  defp load_proposal!(%RepairProposal{} = proposal), do: Domain.get_repair_proposal!(proposal.id)

  defp load_proposal!(id), do: Domain.get_repair_proposal!(id)
end
