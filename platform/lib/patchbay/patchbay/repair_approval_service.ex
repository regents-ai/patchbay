defmodule Patchbay.Patchbay.RepairApprovalService do
  @moduledoc """
  The approval and publication boundary for a repair proposal.

  Two callers reach it, and both name themselves: the owner's control on the
  page, and Patchbay's own worker acting on a report it verified against its
  record. No tool a browser agent can call reaches this service, and nothing a
  caller sends can stand in for the name it approves under.

  The room is locked first, the canary is then recomputed against the locked
  rows, and only then is anything written; the rules about which record may
  move where live on the resources themselves.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    CanaryRunner,
    Invocation,
    RepairProposal,
    Room,
    RoomTimeline,
    ToolPublisher,
    ToolRevision
  }

  @spec approve_and_publish!(RepairProposal.t() | binary(), binary(), keyword()) ::
          RepairProposal.t()
  def approve_and_publish!(proposal_or_id, approved_by, opts \\ []) do
    proposal = load_proposal!(proposal_or_id)

    [Room, RepairProposal, ToolRevision, Invocation]
    |> Ash.transact(
      fn -> approve_locked!(proposal.id, approved_by) end,
      Keyword.take(opts, [:timeout])
    )
    |> unwrap!()
  end

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
    candidate_revision = lock_candidate_revision!(proposal)

    case canary_verdict(room, source_invocation, candidate_revision) do
      {:ok, canary} ->
        publish_repair!(proposal, room, candidate_revision, approved_by, canary)

      {:error, message} ->
        raise Ash.Error.to_error_class(
                InvalidAttribute.exception(field: :canary_result, message: message)
              )
    end
  end

  # Approval is the last moment where the room, the failed call and the
  # candidate can still be compared, so the canary is recomputed here rather
  # than trusted from what the proposal recorded.
  defp canary_verdict(room, invocation, candidate_revision) do
    canary =
      CanaryRunner.run(room.source_markdown, invocation.generated_candidate, candidate_revision)

    cond do
      canary.passed != true ->
        {:error, "the candidate no longer passes its canary"}

      canary.candidate_sha256 != invocation.generated_candidate_sha256 ->
        {:error, "the candidate digest no longer matches the failed call"}

      true ->
        {:ok, canary}
    end
  end

  defp publish_repair!(proposal, room, candidate_revision, approved_by, canary) do
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
      "revision_id" => published_revision.id,
      "candidate_sha256" => canary.candidate_sha256
    })

    proposal
  end

  defp reject_locked!(proposal_id) do
    proposal = Domain.get_repair_proposal_for_update!(proposal_id)
    room = Domain.get_room_for_update!(proposal.room_id)
    candidate_revision = lock_candidate_revision!(proposal)

    proposal = Domain.reject_repair_proposal!(proposal)
    Domain.retire_tool_revision!(candidate_revision)

    # The pointer to the proposal on the page is named by no policy, because the
    # rejection this service just recorded is the only thing that may clear it.
    room =
      Domain.set_active_repair_proposal!(room,
        authorize?: false,
        private_arguments: %{proposal_id: nil}
      )

    _room = Domain.record_failure!(room, room.last_failed_invocation_id)

    RoomTimeline.append!(room, :approval_rejected, %{"proposal_id" => proposal.id})

    proposal
  end

  defp unwrap!({:ok, proposal}), do: proposal
  defp unwrap!({:error, error}), do: raise(Ash.Error.to_error_class(error))

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: nil}) do
    raise Ash.Error.to_error_class(
            InvalidAttribute.exception(
              field: :candidate_tool_revision_id,
              message: "proposal has no candidate revision"
            )
          )
  end

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: id}),
    do: Domain.get_tool_revision_for_update!(id)

  defp load_proposal!(%RepairProposal{} = proposal), do: Domain.get_repair_proposal!(proposal.id)

  defp load_proposal!(id), do: Domain.get_repair_proposal!(id)
end
