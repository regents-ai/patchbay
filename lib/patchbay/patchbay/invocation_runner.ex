defmodule Patchbay.Patchbay.InvocationRunner do
  @moduledoc """
  Executes the two audited Patchbay handler adapters.

  `:return_candidate_only` intentionally returns an apparent success without
  touching the visible room. `:apply_candidate_to_editor` applies the cached
  candidate through the Room action. Both paths then use the server-derived
  verifier; a handler result alone never marks an invocation successful.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
    CandidateCache,
    CandidateGenerator,
    Digest,
    Invocation,
    Room,
    RoomTimeline,
    Telemetry,
    ToolRevision,
    VerificationService
  }

  alias Patchbay.Patchbay.OpenAI.Client

  require Ash.Query

  @open_statuses [:started, :executing, :handler_returned, :awaiting_visible_state]

  @spec invoke!(Room.t(), BrowserSession.t(), ToolRevision.t(), map(), keyword()) ::
          Invocation.t()
  def invoke!(
        %Room{} = room,
        %BrowserSession{} = browser_session,
        %ToolRevision{} = revision,
        arguments,
        opts \\ []
      ) do
    case begin_result!(room, browser_session, revision, arguments, opts) do
      {:replay, invocation} -> invocation
      {:new, invocation} -> execute!(invocation, opts)
    end
  end

  @doc "Validates a request and creates its durable invocation row without running the handler."
  @spec begin!(Room.t(), BrowserSession.t(), ToolRevision.t(), map(), keyword()) :: Invocation.t()
  def begin!(
        %Room{} = room,
        %BrowserSession{} = browser_session,
        %ToolRevision{} = revision,
        arguments,
        opts \\ []
      ) do
    {_delivery, invocation} = begin_result!(room, browser_session, revision, arguments, opts)
    invocation
  end

  @doc "Runs the handler for a previously begun invocation."
  @spec execute!(Invocation.t() | binary(), keyword()) :: Invocation.t()
  def execute!(invocation_or_id, opts \\ []) do
    invocation = load_invocation!(invocation_or_id)

    if invocation.effective_status == :started do
      room = Domain.get_room_by_id!(invocation.room_id)
      browser_session = Domain.get_browser_session!(invocation.browser_session_id)
      revision = Domain.get_tool_revision!(invocation.tool_revision_id)

      try do
        ensure_invocation_epoch_current!(invocation, room)
        ensure_current_revision!(room, browser_session, revision)
        ensure_apply_session_current!(room, browser_session, revision)

        execute_new_invocation!(
          invocation,
          room,
          browser_session,
          revision,
          invocation.arguments,
          opts
        )
      rescue
        error ->
          terminalize_failed_invocation(invocation, room, browser_session, error)
          reraise(error, __STACKTRACE__)
      end
    else
      invocation
    end
  end

  @doc "Durably cancels an invocation that has not reached a terminal state."
  @spec cancel!(Invocation.t()) :: Invocation.t()
  def cancel!(%Invocation{} = invocation) do
    if invocation.effective_status in @open_statuses do
      Domain.mark_invocation_cancelled!(invocation)
    else
      invocation
    end
  end

  @doc "Cancels unfinished work for a room, optionally scoped to one browser lifecycle."
  @spec cancel_open!(Room.t(), keyword()) :: [Invocation.t()]
  def cancel_open!(%Room{} = room, opts \\ []) do
    browser_session_id = Keyword.get(opts, :browser_session_id)
    invocation_epoch = Keyword.get(opts, :invocation_epoch)

    Invocation
    |> Ash.Query.for_read(:for_update)
    |> Ash.Query.filter(room_id == ^room.id and effective_status in ^@open_statuses)
    |> maybe_filter_browser_session(browser_session_id)
    |> maybe_filter_invocation_epoch(invocation_epoch)
    |> Ash.read!()
    |> Enum.map(&cancel!/1)
  end

  defp begin_result!(room, browser_session, revision, arguments, opts) do
    arguments = normalize_arguments!(arguments)
    request_uuid = Keyword.get(opts, :request_uuid, Ash.UUID.generate())
    room = Domain.get_room_by_id!(room.id)
    browser_session = Domain.get_browser_session!(browser_session.id)
    revision = Domain.get_tool_revision!(revision.id)

    case find_by_request_uuid(request_uuid) do
      %Invocation{} = existing ->
        ensure_idempotent_replay!(existing, room, browser_session, revision, arguments)
        {:replay, existing}

      nil ->
        begin_new_locked!(room, browser_session, revision, arguments, request_uuid, opts)
    end
  end

  defp begin_new_locked!(room, browser_session, revision, arguments, request_uuid, opts) do
    expected_epoch = Keyword.get(opts, :invocation_epoch, room.invocation_epoch)

    case Ash.transact(
           [Room, BrowserSession, ToolRevision, Invocation],
           fn ->
             begin_new_in_transaction!(
               room.id,
               browser_session.id,
               revision.id,
               arguments,
               request_uuid,
               expected_epoch
             )
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, result} -> result
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp begin_new_in_transaction!(
         room_id,
         browser_session_id,
         revision_id,
         arguments,
         request_uuid,
         expected_epoch
       ) do
    room = Domain.get_room_for_update!(room_id)
    browser_session = Domain.get_browser_session_for_update!(browser_session_id)
    revision = Domain.get_tool_revision_for_update!(revision_id)

    case find_by_request_uuid(request_uuid) do
      %Invocation{} = existing ->
        ensure_idempotent_replay!(existing, room, browser_session, revision, arguments)
        {:replay, existing}

      nil ->
        start_locked_invocation!(
          room,
          browser_session,
          revision,
          arguments,
          request_uuid,
          expected_epoch
        )
    end
  end

  defp start_locked_invocation!(
         room,
         browser_session,
         revision,
         arguments,
         request_uuid,
         expected_epoch
       ) do
    if expected_epoch != room.invocation_epoch do
      raise ArgumentError, "invocation belongs to an earlier room lifecycle"
    end

    ensure_current_revision!(room, browser_session, revision)
    validate_arguments!(revision.input_schema, arguments)
    ensure_apply_session_current!(room, browser_session, revision)

    attrs = %{
      request_uuid: request_uuid,
      invocation_epoch: room.invocation_epoch,
      room_id: room.id,
      browser_session_id: browser_session.id,
      tool_revision_id: revision.id,
      tool_contract_sha256: revision.contract_sha256,
      arguments: arguments
    }

    create_or_replay!(attrs, request_uuid, room, browser_session, revision, arguments)
  end

  defp execute_new_invocation!(
         invocation,
         room,
         browser_session,
         revision,
         arguments,
         opts
       ) do
    invocation = begin_execution!(invocation, room, browser_session, revision, opts)

    Telemetry.invocation_start(%{
      room_id: room.id,
      browser_session_id: browser_session.id,
      invocation_id: invocation.id,
      tool_generation: revision.generation,
      tool_name: revision.name,
      contract_sha256: invocation.tool_contract_sha256,
      arguments_sha256: invocation.arguments_sha256
    })

    started_at = System.monotonic_time()

    case generated_for_invocation(room, arguments, opts) do
      {:ok, generated} ->
        committed = commit_generated!(invocation, revision, generated, opts)

        emit_handler_stop(started_at, room, browser_session, revision, committed, generated, nil)

        committed

      {:error, reason} ->
        committed = commit_generation_error!(invocation, reason, opts)

        emit_handler_stop(
          started_at,
          room,
          browser_session,
          revision,
          committed,
          nil,
          :MODEL_GENERATION_FAILED
        )

        committed
    end
  end

  defp emit_handler_stop(
         started_at,
         room,
         browser_session,
         revision,
         invocation,
         generated,
         failure_code
       ) do
    usage = Client.normalize_usage(generated && Map.get(generated, :usage))

    Telemetry.invocation_handler_stop(
      %{
        duration: System.monotonic_time() - started_at,
        input_tokens: Map.get(usage, "input_tokens"),
        output_tokens: Map.get(usage, "output_tokens")
      },
      %{
        room_id: room.id,
        browser_session_id: browser_session.id,
        invocation_id: invocation.id,
        tool_generation: revision.generation,
        tool_name: revision.name,
        contract_sha256: invocation.tool_contract_sha256,
        arguments_sha256: invocation.arguments_sha256,
        fallback_used: (generated && Map.get(generated, :fallback_used)) || false,
        failure_code: failure_code,
        receipt: invocation.receipt
      }
    )
  end

  defp begin_execution!(invocation, room, browser_session, revision, opts) do
    transact_invocation!(
      invocation,
      opts,
      fn current, locked_room, locked_session, locked_revision ->
        ensure_invocation_epoch_current!(current, locked_room)
        ensure_invocation_status!(current, :started)
        ensure_current_revision!(locked_room, locked_session, locked_revision)
        ensure_apply_session_current!(locked_room, locked_session, locked_revision)

        current = Domain.mark_invocation_executing!(current)

        RoomTimeline.append!(
          locked_room,
          :invocation_started,
          %{
            "invocation_id" => current.id,
            "tool_revision_id" => locked_revision.id,
            "generation" => locked_revision.generation
          },
          browser_session_id: browser_session.id
        )

        current
      end,
      room: room,
      browser_session: browser_session,
      revision: revision
    )
  end

  defp commit_generated!(invocation, revision, generated, opts) do
    transact_invocation!(
      invocation,
      opts,
      fn current, room, browser_session, locked_revision ->
        ensure_invocation_epoch_current!(current, room)
        ensure_invocation_status!(current, :executing)
        ensure_current_revision!(room, browser_session, locked_revision)
        ensure_apply_session_current!(room, browser_session, locked_revision)

        current =
          Domain.record_handler_return!(current, %{
            handler_result: handler_result(locked_revision, generated, room),
            handler_reported_success: true,
            generated_candidate: generated.candidate_markdown,
            handler_returned_at: DateTime.utc_now()
          })

        RoomTimeline.append!(
          room,
          :handler_returned,
          %{
            "invocation_id" => current.id,
            "reported_success" => true,
            "applied" => locked_revision.handler_adapter == :apply_candidate_to_editor,
            "fallback_used" => generated.fallback_used
          },
          browser_session_id: browser_session.id
        )

        if locked_revision.handler_adapter == :apply_candidate_to_editor do
          ensure_room_ready_for_retry!(room)
          room = Domain.begin_retry!(room)
          Domain.apply_candidate!(room, generated.candidate_markdown)
        end

        Domain.mark_invocation_awaiting_visible_state!(current)
      end,
      revision: revision
    )
  end

  defp commit_generation_error!(invocation, reason, opts) do
    transact_invocation!(invocation, opts, fn current, room, browser_session, _revision ->
      ensure_invocation_epoch_current!(current, room)
      ensure_invocation_status!(current, :executing)

      current =
        Domain.record_handler_return!(current, %{
          handler_result: %{
            "reported_success" => false,
            "applied" => false,
            "error" => inspect(reason)
          },
          handler_reported_success: false,
          handler_returned_at: DateTime.utc_now()
        })

      current = Domain.mark_invocation_errored!(current)

      RoomTimeline.append!(
        room,
        :platform_error,
        %{
          "invocation_id" => current.id,
          "failure" => "MODEL_GENERATION_FAILED"
        },
        browser_session_id: browser_session.id
      )

      current
    end)
  end

  defp terminalize_failed_invocation(invocation, room, browser_session, error) do
    invocation = Domain.get_invocation!(invocation.id)

    unless invocation.effective_status in [
             :verified_failure,
             :verified_success,
             :errored,
             :cancelled
           ] do
      Domain.mark_invocation_errored!(invocation)

      RoomTimeline.append!(
        room,
        :platform_error,
        %{
          "invocation_id" => invocation.id,
          "failure" => "INVOCATION_TRANSITION_FAILED",
          "error" => Exception.message(error)
        },
        browser_session_id: browser_session.id
      )
    end
  rescue
    _ -> :ok
  end

  @doc "Runs the currently desired revision for an existing invocation's arguments."
  @spec retry!(Invocation.t() | binary(), BrowserSession.t(), keyword()) :: Invocation.t()
  def retry!(invocation_or_id, %BrowserSession{} = browser_session, opts \\ []) do
    invocation = load_invocation!(invocation_or_id)
    room = Domain.get_room_by_id!(invocation.room_id)
    revision = desired_revision!(room)

    generated = durable_candidate!(invocation, room)
    generated = validate_retry_cache!(generated, invocation, room)

    invoke!(
      room,
      browser_session,
      revision,
      invocation.arguments,
      opts
      |> Keyword.put(:durable_candidate, generated)
      |> Keyword.put(:request_uuid, Keyword.get(opts, :request_uuid, Ash.UUID.generate()))
    )
  end

  @doc "Verifies a browser-captured post-state and updates the room projection."
  @spec verify!(Invocation.t() | binary(), map(), keyword()) :: Invocation.t()
  def verify!(invocation_or_id, post_state, opts \\ []) when is_map(post_state) do
    invocation = load_invocation!(invocation_or_id)
    room = Domain.get_room_by_id!(invocation.room_id)
    browser_session = Domain.get_browser_session!(invocation.browser_session_id)

    verify_and_update_room!(
      invocation,
      room,
      browser_session,
      Keyword.put(opts, :post_state, post_state)
    )
  end

  defp verify_and_update_room!(invocation, room, browser_session, opts) do
    case Ash.transact(
           [Room, Invocation, Patchbay.Patchbay.Verification, Patchbay.Patchbay.RoomEvent],
           fn -> verify_locked!(invocation.id, room.id, browser_session.id, opts) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, verified} ->
        if verified.effective_status == :verified_success do
          Telemetry.goal_verified(%{
            room_id: verified.room_id,
            invocation_id: verified.id,
            tool_generation: room.desired_tool_generation
          })
        end

        verified

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp verify_locked!(invocation_id, room_id, browser_session_id, opts) do
    room = Domain.get_room_for_update!(room_id)
    invocation = Domain.get_invocation_for_update!(invocation_id)
    ensure_invocation_epoch_current!(invocation, room)
    ensure_verifiable_status!(invocation)
    post_state = Keyword.get(opts, :post_state, visible_state(room))

    verified = VerificationService.verify_invocation!(invocation, %{post_state: post_state}, opts)

    RoomTimeline.append!(
      room,
      :visible_state_observed,
      %{
        "invocation_id" => verified.id,
        "ui_revision" => get_in(verified.post_state, ["ui_revision"])
      },
      browser_session_id: browser_session_id
    )

    RoomTimeline.append!(
      room,
      verification_event(verified),
      %{
        "invocation_id" => verified.id,
        "failure_code" => verified.failure_code
      },
      browser_session_id: browser_session_id
    )

    record_verification!(room, verified)

    verified
  end

  defp verification_event(%Invocation{effective_status: :verified_success}),
    do: :verification_passed

  defp verification_event(_invocation), do: :verification_failed

  defp record_verification!(room, %Invocation{effective_status: :verified_success} = verified) do
    Domain.mark_verified!(room)
    RoomTimeline.append!(room, :goal_verified, %{"invocation_id" => verified.id})
  end

  defp record_verification!(room, verified), do: Domain.record_failure!(room, verified.id)

  defp generated_for_invocation(room, arguments, opts) do
    case Keyword.get(opts, :durable_candidate) do
      nil ->
        CandidateGenerator.generate(
          room.source_markdown,
          arguments,
          Keyword.put(opts, :room_id, room.id)
        )

      generated ->
        case CandidateGenerator.validate_generated(generated, room.source_markdown, arguments) do
          :ok -> {:ok, generated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp transact_invocation!(invocation, opts, fun, records \\ []) do
    case Ash.transact(
           [
             Room,
             BrowserSession,
             ToolRevision,
             Invocation,
             Patchbay.Patchbay.Verification,
             Patchbay.Patchbay.RoomEvent
           ],
           fn ->
             room = Domain.get_room_for_update!(invocation.room_id)
             invocation = Domain.get_invocation_for_update!(invocation.id)

             browser_session =
               records
               |> Keyword.get(:browser_session)
               |> browser_session_id(invocation)
               |> Domain.get_browser_session_for_update!()

             revision =
               records
               |> Keyword.get(:revision)
               |> revision_id(invocation)
               |> Domain.get_tool_revision_for_update!()

             fun.(invocation, room, browser_session, revision)
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, result} -> result
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp browser_session_id(%BrowserSession{id: id}, _invocation), do: id
  defp browser_session_id(_record, invocation), do: invocation.browser_session_id

  defp revision_id(%ToolRevision{id: id}, _invocation), do: id
  defp revision_id(_record, invocation), do: invocation.tool_revision_id

  defp ensure_room_ready_for_retry!(%Room{status: :repaired}), do: :ok

  defp ensure_room_ready_for_retry!(_room) do
    raise ArgumentError, "room is not ready for a retry"
  end

  defp handler_result(%{handler_adapter: :apply_candidate_to_editor}, generated, room) do
    %{
      "reported_success" => true,
      "applied" => true,
      "verified" => true,
      "candidate_sha256" => generated.candidate_sha256,
      "ui_revision" => room.ui_revision + 1,
      "change_summary" => generated.change_summary,
      "warnings" => generated.warnings,
      "candidate_provenance" => candidate_provenance(generated)
    }
  end

  defp handler_result(_revision, generated, _room) do
    %{
      "reported_success" => true,
      "applied" => false,
      "verified" => false,
      "candidate_sha256" => generated.candidate_sha256,
      "change_summary" => generated.change_summary,
      "warnings" => generated.warnings,
      "candidate_provenance" => candidate_provenance(generated)
    }
  end

  defp candidate_provenance(generated) do
    %{
      "cache_variant" => generated.cache_variant,
      "input_sha256" => generated.input_sha256,
      "model" => generated.model,
      "model_response_id" => generated.model_response_id,
      "prompt_version" => generated.prompt_version,
      "fallback_used" => generated.fallback_used,
      "fallback_reason" => generated.fallback_reason,
      "usage" => Client.normalize_usage(Map.get(generated, :usage))
    }
  end

  defp visible_state(room) do
    candidate_present =
      is_binary(room.candidate_markdown) and String.trim(room.candidate_markdown) != ""

    %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{
        "present" => candidate_present,
        "sha256" => if(candidate_present, do: room.candidate_sha256, else: nil)
      }
    }
  end

  defp desired_revision!(room) do
    case Domain.list_tool_revisions!(
           query: [
             filter: [
               room_id: room.id,
               generation: room.desired_tool_generation,
               status: :desired
             ],
             limit: 1
           ]
         ) do
      [revision | _] -> revision
      [] -> raise ArgumentError, "room has no desired tool revision"
    end
  end

  defp ensure_current_revision!(room, browser_session, revision) do
    cond do
      browser_session.room_id != room.id ->
        raise ArgumentError, "browser session belongs to another room"

      revision.room_id != room.id ->
        raise ArgumentError, "tool revision belongs to another room"

      revision.status != :desired ->
        raise ArgumentError, "tool revision is not desired"

      revision.generation != room.desired_tool_generation ->
        raise ArgumentError, "tool revision is stale"

      true ->
        :ok
    end
  end

  defp ensure_invocation_epoch_current!(invocation, room) do
    if invocation.invocation_epoch == room.invocation_epoch do
      :ok
    else
      raise ArgumentError, "invocation belongs to an earlier room lifecycle"
    end
  end

  defp ensure_invocation_status!(%Invocation{effective_status: expected}, expected), do: :ok

  defp ensure_invocation_status!(_invocation, expected) do
    raise ArgumentError, "invocation is no longer #{expected}"
  end

  defp ensure_verifiable_status!(%Invocation{effective_status: status})
       when status in [:awaiting_visible_state, :verified_failure, :verified_success],
       do: :ok

  defp ensure_verifiable_status!(_invocation) do
    raise ArgumentError, "invocation is no longer awaiting visible proof"
  end

  defp ensure_apply_session_current!(room, browser_session, revision) do
    if revision.handler_adapter == :apply_candidate_to_editor do
      observed_contract = fetch(browser_session.observed_contracts, revision.name)

      cond do
        browser_session.webmcp_supported != true ->
          raise ArgumentError, "browser session is not WebMCP capable"

        not is_nil(browser_session.disconnected_at) ->
          raise ArgumentError, "browser session is disconnected"

        browser_session.desired_generation != room.desired_tool_generation or
            browser_session.observed_generation != room.desired_tool_generation ->
          raise ArgumentError, "browser session is stale"

        revision.name not in browser_session.observed_tool_names ->
          raise ArgumentError, "browser session has not observed the tool revision"

        observed_contract != revision.contract_sha256 ->
          raise ArgumentError, "browser session has not observed the tool contract"

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp ensure_idempotent_replay!(existing, room, browser_session, revision, arguments) do
    if existing.room_id != room.id or existing.browser_session_id != browser_session.id or
         existing.invocation_epoch != room.invocation_epoch or
         existing.tool_revision_id != revision.id or
         existing.arguments_sha256 != Digest.arguments_sha256(arguments) do
      raise ArgumentError, "request UUID is already bound to different invocation evidence"
    end
  end

  defp create_or_replay!(attrs, request_uuid, room, browser_session, revision, arguments) do
    {:new, Domain.record_invocation!(attrs)}
  rescue
    error in Ash.Error.Invalid ->
      case find_by_request_uuid(request_uuid) do
        %Invocation{} = existing ->
          ensure_idempotent_replay!(existing, room, browser_session, revision, arguments)
          {:replay, existing}

        nil ->
          reraise error, __STACKTRACE__
      end
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  defp fetch(_map, _key), do: nil

  defp maybe_filter_browser_session(query, nil), do: query

  defp maybe_filter_browser_session(query, browser_session_id),
    do: Ash.Query.filter(query, browser_session_id == ^browser_session_id)

  defp maybe_filter_invocation_epoch(query, nil), do: query

  defp maybe_filter_invocation_epoch(query, invocation_epoch),
    do: Ash.Query.filter(query, invocation_epoch == ^invocation_epoch)

  defp durable_generated(invocation) do
    provenance = fetch(invocation.handler_result, :candidate_provenance)

    %{
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
  end

  defp durable_candidate!(invocation, room) do
    candidate = invocation.generated_candidate
    candidate_sha256 = invocation.generated_candidate_sha256
    generation_key = invocation.generation_key

    cond do
      invocation.effective_status != :verified_failure ->
        raise ArgumentError, "retry requires a verified failure invocation"

      not is_binary(candidate) or not is_binary(candidate_sha256) ->
        raise ArgumentError, "retry requires durable candidate evidence"

      Digest.sha256(candidate) != candidate_sha256 ->
        raise ArgumentError, "retry candidate digest is invalid"

      not is_binary(generation_key) or
          generation_key != Digest.generation_key(room.source_sha256, invocation.arguments) ->
        raise ArgumentError, "retry generation key is stale"

      true ->
        validated_generated!(invocation, room)
    end
  end

  defp validated_generated!(invocation, room) do
    generated = durable_generated(invocation)

    case CandidateGenerator.validate_generated(
           generated,
           room.source_markdown,
           invocation.arguments
         ) do
      :ok ->
        generated

      {:error, reason} ->
        raise ArgumentError, "retry candidate evidence is invalid: #{inspect(reason)}"
    end
  end

  defp validate_retry_cache!(generated, invocation, room) do
    variant = generated.cache_variant

    case CandidateCache.get(invocation.generation_key, variant: variant) do
      {:ok, cached} ->
        if same_candidate_evidence?(cached, generated) and
             CandidateGenerator.validate_generated(
               cached,
               room.source_markdown,
               invocation.arguments
             ) ==
               :ok do
          generated
        else
          CandidateCache.delete(invocation.generation_key, variant: variant)
          generated
        end

      {:error, _reason} ->
        generated
    end
    |> then(fn durable ->
      case CandidateCache.put(invocation.generation_key, durable, variant: variant) do
        :ok ->
          durable

        {:error, reason} ->
          raise ArgumentError, "retry candidate cache is invalid: #{inspect(reason)}"
      end
    end)
  end

  defp same_candidate_evidence?(left, right) do
    Enum.all?(
      ~w(candidate_markdown candidate_sha256 generation_key input_sha256 cache_variant model model_response_id prompt_version fallback_used fallback_reason),
      fn key -> fetch(left, String.to_atom(key)) == fetch(right, String.to_atom(key)) end
    )
  end

  defp validate_arguments!(schema, arguments) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    required = Map.get(schema, "required", Map.get(schema, :required, []))

    additional_properties =
      Map.get(schema, "additionalProperties", Map.get(schema, :additionalProperties, true))

    keys = Map.keys(arguments) |> Enum.map(&to_string/1)
    property_keys = Map.keys(properties) |> Enum.map(&to_string/1)

    cond do
      Enum.any?(
        required,
        &(not Map.has_key?(arguments, &1) and not Map.has_key?(arguments, atom_key(arguments, &1)))
      ) ->
        raise ArgumentError, "required invocation argument missing"

      additional_properties == false and Enum.any?(keys, &(&1 not in property_keys)) ->
        raise ArgumentError, "unknown invocation argument"

      not valid_instruction?(arguments) ->
        raise ArgumentError, "instructions must be a non-empty string of at most 1000 characters"

      true ->
        :ok
    end
  end

  defp validate_arguments!(_schema, _arguments),
    do: raise(ArgumentError, "tool input schema is invalid")

  defp valid_instruction?(arguments) do
    value = Map.get(arguments, "instructions", Map.get(arguments, :instructions))

    is_binary(value) and String.trim(value) != "" and
      Enum.count_until(String.codepoints(value), 1_001) <= 1_000
  end

  defp atom_key(map, key) when is_binary(key) do
    Enum.find(Map.keys(map), fn candidate ->
      is_atom(candidate) and Atom.to_string(candidate) == key
    end)
  end

  defp normalize_arguments!(arguments) when is_map(arguments) do
    Enum.reduce(arguments, %{}, fn {key, value}, normalized ->
      key = to_string(key)

      if Map.has_key?(normalized, key) do
        raise ArgumentError, "invocation argument keys collide after JSON normalization"
      end

      Map.put(normalized, key, value)
    end)
  end

  defp normalize_arguments!(_), do: raise(ArgumentError, "invocation arguments must be a map")

  defp find_by_request_uuid(request_uuid) do
    Domain.get_invocation_by_request_uuid!(request_uuid)
  rescue
    _error in [Ash.Error.Query.NotFound, Ash.Error.Invalid] -> nil
  end

  defp load_invocation!(%Invocation{} = invocation), do: Domain.get_invocation!(invocation.id)

  defp load_invocation!(id), do: Domain.get_invocation!(id)
end
