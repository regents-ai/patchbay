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
    Digest,
    Invocation,
    CanaryRunner,
    RepairProposal,
    Room,
    RoomTimeline,
    ToolPublisher,
    ToolRevision
  }

  require Ash.Query

  @spec approve_and_publish!(RepairProposal.t() | binary(), binary(), keyword() | map()) ::
          RepairProposal.t()
  def approve_and_publish!(proposal_or_id, approved_by, opts \\ [])

  def approve_and_publish!(proposal_or_id, approved_by, opts) when is_binary(approved_by) do
    if String.trim(approved_by) == "", do: raise(ArgumentError, "human approver is required")

    opts = normalize_opts(opts)
    proposal = load_proposal!(proposal_or_id, opts)
    action_opts = action_opts(opts)

    case Ash.transact(
           [Room, RepairProposal, ToolRevision, Invocation],
           fn ->
             proposal = lock_proposal!(proposal.id, opts)
             room = lock_room!(proposal.room_id, opts)

             source_invocation = lock_invocation!(proposal.source_invocation_id, opts)

             source_revision = lock_revision!(proposal.source_tool_revision_id, opts)
             candidate_revision = lock_candidate_revision!(proposal, opts)

             validate_fresh!(
               proposal,
               room,
               source_invocation,
               source_revision,
               candidate_revision
             )

             proposal = Domain.approve_repair_proposal!(proposal, approved_by, action_opts)
             Domain.mark_tool_revision_approved!(candidate_revision, action_opts)
             Domain.begin_publication!(room, action_opts)

             RoomTimeline.append!(
               room,
               :approval_granted,
               %{
                 "proposal_id" => proposal.id,
                 "approved_by" => approved_by
               },
               action_opts
             )

             published_revision = ToolPublisher.publish!(candidate_revision, action_opts)
             proposal = Domain.publish_repair_proposal!(proposal, action_opts)
             room = Domain.get_room_by_id!(room.id, read_opts(opts))
             Domain.mark_repaired!(room, action_opts)

             RoomTimeline.append!(
               room,
               :publication_requested,
               %{
                 "proposal_id" => proposal.id,
                 "revision_id" => published_revision.id
               },
               action_opts
             )

             proposal
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, proposal} -> proposal
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  def approve_and_publish!(_proposal, _approved_by, _opts),
    do: raise(ArgumentError, "human approver is required")

  @spec reject!(RepairProposal.t() | binary(), keyword() | map()) :: RepairProposal.t()
  def reject!(proposal_or_id, opts \\ []) do
    opts = normalize_opts(opts)
    proposal = load_proposal!(proposal_or_id, opts)
    action_opts = action_opts(opts)

    case Ash.transact(
           [Room, RepairProposal, ToolRevision],
           fn ->
             proposal = lock_proposal!(proposal.id, opts)
             room = lock_room!(proposal.room_id, opts)
             candidate_revision = lock_candidate_revision!(proposal, opts)

             if proposal.status != :ready_for_approval do
               raise ArgumentError, "proposal is not ready for rejection"
             end

             proposal = Domain.reject_repair_proposal!(proposal, action_opts)
             Domain.retire_tool_revision!(candidate_revision, action_opts)

             room =
               Domain.set_active_repair_proposal!(
                 room,
                 Keyword.put(action_opts, :private_arguments, %{proposal_id: nil})
               )

             _room = Domain.record_failure!(room, room.last_failed_invocation_id, action_opts)

             RoomTimeline.append!(
               room,
               :approval_rejected,
               %{"proposal_id" => proposal.id},
               action_opts
             )

             proposal
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, proposal} -> proposal
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp validate_fresh!(proposal, room, invocation, source_revision, candidate_revision) do
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

      room.last_failed_invocation_id != invocation.id ->
        raise ArgumentError, "source invocation is stale"

      invocation.room_id != room.id or source_revision.room_id != room.id ->
        raise ArgumentError, "proposal relationships are stale"

      source_revision.status != :desired ->
        raise ArgumentError, "source tool revision is stale"

      room.desired_tool_generation != source_revision.generation ->
        raise ArgumentError, "desired tool revision is stale"

      source_state_digest(invocation) != room.source_sha256 ->
        raise ArgumentError, "source state changed since the failed invocation"

      Digest.generation_key(room.source_sha256, invocation.arguments) != invocation.generation_key ->
        raise ArgumentError, "source invocation generation key is stale"

      invocation.generation_key != proposal.input_sha256 ->
        raise ArgumentError, "proposal input digest is stale"

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
        canary =
          CanaryRunner.run(
            room.source_markdown,
            invocation.generated_candidate,
            candidate_revision
          )

        if canary.passed != true or
             canary.candidate_sha256 != invocation.generated_candidate_sha256 do
          raise ArgumentError, "candidate canary has not passed"
        end

        canary
    end
  end

  defp source_state_digest(invocation) do
    get_in(invocation.pre_state, ["source", "sha256"]) ||
      get_in(invocation.pre_state, [:source, :sha256])
  end

  defp canary_candidate_digest(proposal) do
    canary = proposal.canary_result || %{}
    get_in(canary, ["candidate_sha256"]) || get_in(canary, [:candidate_sha256])
  end

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: nil}, _opts),
    do: raise(ArgumentError, "proposal has no candidate revision")

  defp lock_candidate_revision!(%RepairProposal{candidate_tool_revision_id: id}, opts),
    do: lock_revision!(id, opts)

  defp load_proposal!(%RepairProposal{} = proposal, opts),
    do: Domain.get_repair_proposal!(proposal.id, read_opts(opts))

  defp load_proposal!(id, opts), do: Domain.get_repair_proposal!(id, read_opts(opts))

  defp lock_proposal!(id, opts) do
    RepairProposal
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp lock_room!(id, opts) do
    Room
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp lock_invocation!(id, opts) do
    Invocation
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp lock_revision!(id, opts) do
    ToolRevision
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(_), do: []

  defp query_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

  defp execution_opts(opts),
    do: Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope, :query])

  defp read_opts(opts), do: Keyword.drop(opts, [:query, :timeout])
  defp action_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])
end
