defmodule Patchbay.Patchbay.RepairPlanner do
  @moduledoc """
  Builds one bounded repair proposal from a failed invocation.

  The planner validates the model-shaped DSL, creates a candidate revision in
  `:candidate`, runs the deterministic canary, and only then marks both the
  revision and proposal ready for human approval.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    CanaryRunner,
    CandidateGenerator,
    Digest,
    Fixtures,
    Invocation,
    ModelBudget,
    RepairDSL,
    RepairPolicy,
    RepairProposal,
    Room,
    RoomTimeline,
    Telemetry,
    ToolRevision
  }

  alias Patchbay.Patchbay.OpenAI.Client

  @spec propose!(Invocation.t() | binary(), keyword()) :: RepairProposal.t()
  def propose!(invocation_or_id, opts \\ []) do
    {invocation, candidate, repair} = prepare_plan(invocation_or_id, opts)
    commit_proposal!(invocation, candidate, repair, opts)
  end

  @doc """
  Works out what the repair would be, without writing anything.

  All external inference, parsing, and policy validation happen here, so a
  rejected response cannot strand the room in `:diagnosing` or leave an orphan
  revision behind.
  """
  @spec prepare_plan(Invocation.t() | binary(), keyword()) ::
          {Invocation.t(), map(), map()}
  def prepare_plan(invocation_or_id, opts \\ []) do
    invocation = load_invocation!(invocation_or_id)
    room = Domain.get_room_by_id!(invocation.room_id)
    source_revision = Domain.get_tool_revision!(invocation.tool_revision_id)

    ensure_failed_latest!(invocation, room)

    candidate = candidate_for!(invocation, room)
    model_started_at = System.monotonic_time()
    {plan, plan_metadata} = plan_for!(invocation, room, source_revision, opts)
    emit_model_stop(model_started_at, room, invocation, plan_metadata)

    {:ok, revision_attributes} = RepairPolicy.revision_attributes(plan, source_revision)

    {invocation, candidate,
     %{plan: plan, metadata: plan_metadata, revision_attributes: revision_attributes}}
  end

  @doc """
  Writes the prepared repair: the candidate revision, its canary result, and
  the proposal the owner is asked to approve, in one locked transaction.
  """
  @spec commit_proposal!(Invocation.t(), map(), map(), keyword()) :: RepairProposal.t()
  def commit_proposal!(%Invocation{} = invocation, candidate, repair, opts \\ []) do
    case Ash.transact(
           [Room, Invocation, ToolRevision, RepairProposal],
           fn -> commit_locked!(invocation, candidate, repair, opts) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, {proposal, revision_id, canary, canary_duration}} ->
        emit_canary_stop(canary_duration, proposal, revision_id, canary)
        proposal

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp commit_locked!(invocation, candidate, repair, opts) do
    invocation = Domain.get_invocation_for_update!(invocation.id)
    room = Domain.get_room_for_update!(invocation.room_id)
    source_revision = Domain.get_tool_revision!(invocation.tool_revision_id)

    ensure_failed_latest!(invocation, room)
    ensure_candidate_unchanged!(candidate_for!(invocation, room), candidate)

    room = Domain.begin_diagnosis!(room)

    RoomTimeline.append!(room, :repair_requested, %{"invocation_id" => invocation.id})

    revision =
      repair.revision_attributes
      |> Map.delete(:contract_sha256)
      |> Domain.create_tool_revision!()

    canary_started_at = System.monotonic_time()
    canary = CanaryRunner.run(room.source_markdown, candidate.candidate_markdown, revision)
    canary_duration = System.monotonic_time() - canary_started_at

    proposal =
      Domain.create_repair_proposal!(%{
        room_id: room.id,
        source_invocation_id: invocation.id,
        source_tool_revision_id: source_revision.id,
        candidate_tool_revision_id: revision.id,
        root_cause: repair.plan.root_cause,
        repair_plan: repair.plan,
        contract_diff: contract_diff(source_revision, revision),
        canary_result: canary,
        risk_notes: repair.plan.risk_notes,
        model: repair.metadata[:model] || candidate.model,
        model_response_id: repair.metadata[:model_response_id] || candidate.model_response_id,
        prompt_version: repair.metadata[:prompt_version] || plan_prompt_version(opts),
        usage: %{
          "candidate" => candidate.usage,
          "repair_plan" => Client.normalize_usage(repair.metadata[:usage])
        },
        input_sha256: candidate.generation_key
      })

    RoomTimeline.append!(
      room,
      canary_event(canary),
      %{
        "proposal_id" => proposal.id,
        "revision_id" => revision.id,
        "passed" => canary.passed
      }
    )

    proposal = finalize_proposal!(proposal, room, revision, canary)

    {proposal, revision.id, canary, canary_duration}
  end

  defp ensure_candidate_unchanged!(current, candidate) do
    if current.candidate_sha256 != candidate.candidate_sha256 or
         current.generation_key != candidate.generation_key do
      raise ArgumentError, "repair candidate changed during planning"
    end
  end

  defp canary_event(%{passed: true}), do: :canary_passed
  defp canary_event(_canary), do: :canary_failed

  defp finalize_proposal!(proposal, room, revision, %{passed: true} = canary) do
    revision
    |> Domain.mark_tool_revision_canary_passed!()
    |> Domain.mark_tool_revision_ready_for_approval!()

    proposal = Domain.mark_canary_passed!(proposal, %{canary_result: canary})

    # Parking the room on a human decision is named by no policy, because
    # nothing outside the planner may put a room into that state.
    room =
      room
      |> Domain.mark_repair_ready!()
      |> Domain.await_repair_approval!(authorize?: false)

    # Likewise the pointer to the proposal on the page: the planner is the only
    # thing that knows which proposal the room is now waiting on.
    _room =
      Domain.set_active_repair_proposal!(room,
        authorize?: false,
        private_arguments: %{proposal_id: proposal.id}
      )

    RoomTimeline.append!(room, :repair_proposed, %{"proposal_id" => proposal.id})

    proposal
  end

  defp finalize_proposal!(proposal, room, revision, canary) do
    proposal = Domain.mark_canary_failed!(proposal, %{canary_result: canary})

    # Declaring a repair a failure is named by no policy: only the planner and
    # the room page, which both watched the attempt, may say so.
    room = Domain.mark_repair_failed!(room, authorize?: false)

    # Clearing the pointer belongs to the same decision, so it is reached the
    # same way.
    _room =
      Domain.set_active_repair_proposal!(room,
        authorize?: false,
        private_arguments: %{proposal_id: nil}
      )

    RoomTimeline.append!(
      room,
      :platform_error,
      %{
        "proposal_id" => proposal.id,
        "revision_id" => revision.id,
        "failure" => "CANARY_FAILED",
        "failure_code" => canary.failure_code
      }
    )

    proposal
  end

  defp emit_model_stop(started_at, room, invocation, plan_metadata) do
    usage = Client.normalize_usage(plan_metadata[:usage])

    Telemetry.repair_model_stop(
      %{
        duration: System.monotonic_time() - started_at,
        input_tokens: Map.get(usage, "input_tokens"),
        output_tokens: Map.get(usage, "output_tokens")
      },
      %{
        room_id: room.id,
        invocation_id: invocation.id,
        fallback_used: Map.get(plan_metadata, :fallback_used, false)
      }
    )
  end

  defp emit_canary_stop(duration, proposal, revision_id, canary) do
    Telemetry.repair_canary_stop(
      %{duration: duration},
      %{
        room_id: proposal.room_id,
        invocation_id: proposal.source_invocation_id,
        tool_revision_id: revision_id,
        passed: canary.passed,
        failure_code: canary.failure_code
      }
    )
  end

  @doc "Validates a plan without writing a proposal or revision."
  @spec validate_plan(map() | binary(), ToolRevision.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_plan(plan, source_revision, opts \\ []) do
    with {:ok, plan} <- RepairDSL.parse(plan),
         :ok <- RepairPolicy.validate(plan, source_revision, opts) do
      {:ok, plan}
    end
  end

  defp candidate_for!(invocation, room) do
    if is_binary(invocation.generated_candidate) and
         is_binary(invocation.generated_candidate_sha256) and
         Digest.sha256(invocation.generated_candidate) == invocation.generated_candidate_sha256 and
         is_binary(invocation.generation_key) do
      provenance = fetch(invocation.handler_result, :candidate_provenance)

      generated = %{
        candidate_markdown: invocation.generated_candidate,
        candidate_sha256: invocation.generated_candidate_sha256,
        generation_key: invocation.generation_key,
        input_sha256: fetch(provenance, :input_sha256),
        cache_variant: fetch(provenance, :cache_variant),
        change_summary: fetch(invocation.handler_result, :change_summary) || [],
        warnings: fetch(invocation.handler_result, :warnings) || [],
        model: fetch(provenance, :model),
        model_response_id: fetch(provenance, :model_response_id),
        prompt_version: fetch(provenance, :prompt_version),
        fallback_used: fetch(provenance, :fallback_used),
        fallback_reason: fetch(provenance, :fallback_reason),
        usage: Client.normalize_usage(fetch(provenance, :usage))
      }

      case CandidateGenerator.validate_provenance(
             generated,
             room.source_markdown,
             invocation.arguments
           ) do
        :ok ->
          generated

        {:error, reason} ->
          raise ArgumentError, "repair candidate evidence is invalid: #{inspect(reason)}"
      end
    else
      raise ArgumentError, "repair requires a generated candidate and exact generation key"
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil

  defp plan_for!(invocation, room, source_revision, opts) do
    cond do
      Keyword.has_key?(opts, :plan) ->
        parse_plan!(Keyword.fetch!(opts, :plan), %{model: "provided-plan", fallback_used: false})

      Keyword.get(opts, :fallback, false) ->
        parse_plan!(Fixtures.repair_plan(), %{
          model: "patchbay-demo-fallback",
          model_response_id: "demo-repair-fallback",
          prompt_version: "patchbay-repair-v1",
          fallback_used: true
        })

      true ->
        # The spend limits are checked here rather than around the whole clause
        # so a plan supplied by the caller and the checked-in demo plan stay
        # free of them: neither calls a model.
        plan_from_model!(invocation, room, source_revision, opts)
    end
  end

  defp plan_from_model!(invocation, room, source_revision, opts) do
    case ModelBudget.allow(room.id, :repair) do
      :ok ->
        input = repair_input(invocation, room, source_revision)

        case Client.repair_plan(input, opts) do
          {:ok, %{plan: plan} = metadata} ->
            parse_plan!(plan, metadata)

          {:error, reason} ->
            raise ArgumentError, "repair plan generation failed: #{inspect(reason)}"
        end

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  defp parse_plan!(plan, metadata) do
    case RepairDSL.parse(plan) do
      {:ok, plan} -> {plan, metadata}
      {:error, reason} -> raise ArgumentError, "repair plan rejected: #{inspect(reason)}"
    end
  end

  defp repair_input(invocation, room, source_revision) do
    %{
      "goal" => room.goal_text,
      "source_tool_contract" => %{
        "name" => source_revision.name,
        "description" => source_revision.description,
        "input_schema" => source_revision.input_schema,
        "annotations" => source_revision.annotations,
        "handler_adapter" => source_revision.handler_adapter,
        "output_contract" => source_revision.output_contract,
        "postcondition_set" => source_revision.postcondition_set
      },
      "arguments" => invocation.arguments,
      "handler_result" => invocation.handler_result,
      "pre_state" => invocation.pre_state,
      "post_state" => invocation.post_state,
      "failed_postconditions" => invocation.failure_code
    }
  end

  defp ensure_failed_latest!(%Invocation{} = invocation, %Room{} = room) do
    if room.last_failed_invocation_id != invocation.id or
         invocation.effective_status != :verified_failure do
      raise ArgumentError, "repair requires the room's latest verified failure"
    end
  end

  defp contract_diff(source, candidate) do
    %{
      "description" => %{"from" => source.description, "to" => candidate.description},
      "handler_adapter" => %{
        "from" => source.handler_adapter,
        "to" => candidate.handler_adapter
      },
      "output_contract" => %{"from" => source.output_contract, "to" => candidate.output_contract},
      "postcondition_set" => %{
        "from" => source.postcondition_set,
        "to" => candidate.postcondition_set
      }
    }
  end

  defp load_invocation!(%Invocation{} = invocation), do: Domain.get_invocation!(invocation.id)

  defp load_invocation!(id), do: Domain.get_invocation!(id)

  defp plan_prompt_version(opts), do: Keyword.get(opts, :prompt_version, "patchbay-repair-v1")
end
