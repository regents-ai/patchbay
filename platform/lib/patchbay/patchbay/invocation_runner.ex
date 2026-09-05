defmodule Patchbay.Patchbay.InvocationRunner do
  @moduledoc """
  Executes the two audited Patchbay handler adapters.

  `:return_candidate_only` intentionally returns an apparent success without
  touching the visible room. `:apply_candidate_to_editor` applies the cached
  candidate through the Room action. Both paths then use the server-derived
  verifier; a handler result alone never marks an invocation successful.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
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
    invocation_or_id
    |> load_invocation!()
    |> execute_started!(opts)
  end

  defp execute_started!(%Invocation{effective_status: :started} = invocation, opts) do
    room = Domain.get_room_by_id!(invocation.room_id)
    browser_session = Domain.get_browser_session!(invocation.browser_session_id)
    revision = Domain.get_tool_revision!(invocation.tool_revision_id)

    try do
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
  end

  defp execute_started!(%Invocation{} = invocation, _opts), do: invocation

  @doc "Durably cancels an invocation that has not reached a terminal state."
  @spec cancel!(Invocation.t()) :: Invocation.t()
  def cancel!(%Invocation{} = invocation) do
    if invocation.effective_status in Invocation.open_statuses() do
      Domain.mark_invocation_cancelled!(invocation)
    else
      invocation
    end
  end

  @doc "Cancels unfinished work for a room, optionally scoped to one browser lifecycle."
  @spec cancel_open!(Room.t(), keyword()) :: :ok
  def cancel_open!(%Room{} = room, opts \\ []) do
    Invocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(room_id == ^room.id and effective_status in ^Invocation.open_statuses())
    |> maybe_filter_browser_session(Keyword.get(opts, :browser_session_id))
    |> maybe_filter_invocation_epoch(Keyword.get(opts, :invocation_epoch))
    |> Domain.mark_invocation_cancelled!(bulk_options: [strategy: [:atomic, :stream]])

    :ok
  end

  defp begin_result!(room, browser_session, revision, arguments, opts) do
    arguments = normalize_arguments!(arguments)
    request_uuid = Keyword.get(opts, :request_uuid, Ash.UUID.generate())
    expected_epoch = Keyword.get(opts, :invocation_epoch, room.invocation_epoch)

    case Ash.transact(
           [Room, BrowserSession, ToolRevision, Invocation],
           fn ->
             begin_locked!(
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

  defp begin_locked!(
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
    validate_arguments!(revision.input_schema, arguments)

    # The caller says which run of the room it believes it is in. The create
    # refuses the row if the room has moved on since, so the recorded epoch is
    # always the room's own.
    {:new,
     Domain.record_invocation!(%{
       request_uuid: request_uuid,
       invocation_epoch: expected_epoch,
       room_id: room.id,
       browser_session_id: browser_session.id,
       tool_revision_id: revision.id,
       tool_contract_sha256: revision.contract_sha256,
       arguments: arguments
     })}
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
        current = Domain.mark_invocation_executing!(current)

        RoomTimeline.append!(
          locked_room,
          :invocation_started,
          %{
            "invocation_id" => current.id,
            "tool_revision_id" => locked_revision.id,
            "generation" => locked_revision.generation
          },
          browser_session_id: locked_session.id
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

  # A call that has already reached a verdict, or that something else has
  # already closed, refuses the move and keeps the outcome it was given.
  defp terminalize_failed_invocation(invocation, room, browser_session, error) do
    case Domain.mark_invocation_errored(Domain.get_invocation!(invocation.id)) do
      {:ok, errored} -> append_transition_failure!(room, browser_session, errored, error)
      {:error, _closed} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp append_transition_failure!(room, browser_session, invocation, error) do
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

  @doc "Runs the currently desired revision for an existing invocation's arguments."
  @spec retry!(Invocation.t() | binary(), BrowserSession.t(), keyword()) :: Invocation.t()
  def retry!(invocation_or_id, %BrowserSession{} = browser_session, opts \\ []) do
    invocation = load_invocation!(invocation_or_id)
    room = Domain.get_room_by_id!(invocation.room_id, load: :desired_tool_revision)

    ensure_retryable!(invocation)
    generated = CandidateGenerator.durable_candidate!(invocation, room.source_markdown)

    invoke!(
      room,
      browser_session,
      room.desired_tool_revision,
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
    post_state = Keyword.get(opts, :post_state, visible_state(room))

    verified = VerificationService.verify_invocation!(invocation, %{post_state: post_state}, opts)

    RoomTimeline.append!(
      room,
      :visible_state_observed,
      %{
        "invocation_id" => verified.id,
        "ui_revision" => verified.post_state[:ui_revision]
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

  # Every step of a call takes the same four locks in the same order, whether or
  # not the step reads all four, so two calls on one room can never deadlock.
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
      ui_revision: room.ui_revision,
      source: %{present: true, sha256: room.source_sha256},
      candidate: %{
        present: candidate_present,
        sha256: if(candidate_present, do: room.candidate_sha256, else: nil)
      }
    }
  end

  defp ensure_retryable!(%Invocation{effective_status: :verified_failure}), do: :ok

  defp ensure_retryable!(_invocation),
    do: refuse!(:effective_status, "retry requires a verified failure invocation")

  defp ensure_idempotent_replay!(existing, room, browser_session, revision, arguments) do
    if existing.room_id != room.id or existing.browser_session_id != browser_session.id or
         existing.invocation_epoch != room.invocation_epoch or
         existing.tool_revision_id != revision.id or
         existing.arguments_sha256 != Digest.arguments_sha256(arguments) do
      refuse!(:request_uuid, "request UUID is already bound to different invocation evidence")
    end
  end

  # State rules the services own are refusals a caller can match on, the same
  # way a refusal from a resource action is.
  defp refuse!(field, message) do
    raise Ash.Error.to_error_class(InvalidAttribute.exception(field: field, message: message))
  end

  defp maybe_filter_browser_session(query, nil), do: query

  defp maybe_filter_browser_session(query, browser_session_id),
    do: Ash.Query.filter(query, browser_session_id == ^browser_session_id)

  defp maybe_filter_invocation_epoch(query, nil), do: query

  defp maybe_filter_invocation_epoch(query, invocation_epoch),
    do: Ash.Query.filter(query, invocation_epoch == ^invocation_epoch)

  defp validate_arguments!(schema, arguments) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})

    cond do
      Enum.any?(Map.get(schema, "required", []), &(not Map.has_key?(arguments, &1))) ->
        raise ArgumentError, "required invocation argument missing"

      Map.get(schema, "additionalProperties", true) == false and
          Enum.any?(Map.keys(arguments), &(not Map.has_key?(properties, &1))) ->
        raise ArgumentError, "unknown invocation argument"

      Enum.any?(arguments, fn {key, value} ->
        not valid_argument?(Map.get(properties, key), value)
      end) ->
        raise ArgumentError, "invocation argument does not match the tool input schema"

      true ->
        :ok
    end
  end

  defp validate_arguments!(_schema, _arguments),
    do: raise(ArgumentError, "tool input schema is invalid")

  # The tool contract already says how long a string argument may be, so the
  # bounds are read from it rather than restated here. The minimum is measured
  # after trimming, which is what makes "at least one character" mean a visible
  # one.
  defp valid_argument?(%{"type" => "string"} = property, value) when is_binary(value) do
    maximum = Map.get(property, "maxLength")

    String.length(String.trim(value)) >= Map.get(property, "minLength", 0) and
      (is_nil(maximum) or String.length(value) <= maximum)
  end

  defp valid_argument?(%{"type" => "string"}, _value), do: false

  defp valid_argument?(_property, _value), do: true

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
