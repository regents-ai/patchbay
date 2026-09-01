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
    ToolRevision,
    VerificationService
  }

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
    arguments = normalize_arguments!(arguments)
    request_uuid = Keyword.get(opts, :request_uuid, Ash.UUID.generate())
    action_opts = action_opts(opts)
    room = Domain.get_room_by_id!(room.id, read_opts(opts))
    browser_session = Domain.get_browser_session!(browser_session.id, read_opts(opts))
    revision = Domain.get_tool_revision!(revision.id, read_opts(opts))

    case find_by_request_uuid(request_uuid, opts) do
      %Invocation{} = existing ->
        ensure_idempotent_replay!(existing, room, browser_session, revision, arguments)
        existing

      nil ->
        ensure_current_revision!(room, browser_session, revision)
        validate_arguments!(revision.input_schema, arguments)
        ensure_apply_session_current!(room, browser_session, revision)

        attrs = %{
          request_uuid: request_uuid,
          room_id: room.id,
          browser_session_id: browser_session.id,
          tool_revision_id: revision.id,
          tool_contract_sha256: revision.contract_sha256,
          arguments: arguments
        }

        case create_or_replay!(
               attrs,
               request_uuid,
               room,
               browser_session,
               revision,
               arguments,
               action_opts,
               opts
             ) do
          {:replay, invocation} ->
            invocation

          {:new, invocation} ->
            execute_new_invocation!(
              invocation,
              room,
              browser_session,
              revision,
              arguments,
              opts,
              action_opts
            )
        end
    end
  end

  defp execute_new_invocation!(
         invocation,
         room,
         browser_session,
         revision,
         arguments,
         opts,
         action_opts
       ) do
    RoomTimeline.append!(
      room,
      :invocation_started,
      %{
        "invocation_id" => invocation.id,
        "tool_revision_id" => revision.id,
        "generation" => revision.generation
      },
      Keyword.put(action_opts, :browser_session_id, browser_session.id)
    )

    invocation = Domain.mark_invocation_executing!(invocation, action_opts)

    case generated_for_invocation(room, arguments, opts) do
      {:ok, generated} ->
        invocation =
          Domain.record_handler_return!(
            invocation,
            %{
              handler_result: handler_result(revision, generated, room),
              handler_reported_success: true,
              generated_candidate: generated.candidate_markdown,
              handler_returned_at: DateTime.utc_now()
            },
            action_opts
          )

        RoomTimeline.append!(
          room,
          :handler_returned,
          %{
            "invocation_id" => invocation.id,
            "reported_success" => true,
            "applied" => revision.handler_adapter == :apply_candidate_to_editor,
            "fallback_used" => generated.fallback_used
          },
          Keyword.put(action_opts, :browser_session_id, browser_session.id)
        )

        if revision.handler_adapter == :apply_candidate_to_editor do
          apply_and_verify_locked!(
            invocation,
            revision,
            generated,
            action_opts
          )
        else
          room = Domain.get_room_by_id!(room.id, read_opts(opts))
          verify_and_update_room!(invocation, room, browser_session, action_opts)
        end

      {:error, reason} ->
        invocation =
          Domain.record_handler_return!(
            invocation,
            %{
              handler_result: %{
                "reported_success" => false,
                "applied" => false,
                "error" => inspect(reason)
              },
              handler_reported_success: false,
              handler_returned_at: DateTime.utc_now()
            },
            action_opts
          )

        errored = Domain.mark_invocation_errored!(invocation, action_opts)

        RoomTimeline.append!(
          room,
          :platform_error,
          %{
            "invocation_id" => invocation.id,
            "failure" => "MODEL_GENERATION_FAILED"
          },
          Keyword.put(action_opts, :browser_session_id, browser_session.id)
        )

        errored
    end
  end

  @doc "Runs the currently desired revision for an existing invocation's arguments."
  @spec retry!(Invocation.t() | binary(), BrowserSession.t(), keyword()) :: Invocation.t()
  def retry!(invocation_or_id, %BrowserSession{} = browser_session, opts \\ []) do
    invocation = load_invocation!(invocation_or_id, opts)
    room = Domain.get_room_by_id!(invocation.room_id, read_opts(opts))
    revision = desired_revision!(room, opts)

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
    invocation = load_invocation!(invocation_or_id, opts)
    room = Domain.get_room_by_id!(invocation.room_id, read_opts(opts))
    browser_session = Domain.get_browser_session!(invocation.browser_session_id, read_opts(opts))

    verify_and_update_room!(
      invocation,
      room,
      browser_session,
      Keyword.put(opts, :post_state, post_state)
    )
  end

  defp verify_and_update_room!(invocation, room, browser_session, opts) do
    post_state = Keyword.get(opts, :post_state, visible_state(room))

    verified = VerificationService.verify_invocation!(invocation, %{post_state: post_state}, opts)

    RoomTimeline.append!(
      room,
      :visible_state_observed,
      %{
        "invocation_id" => verified.id,
        "ui_revision" => get_in(verified.post_state, ["ui_revision"])
      },
      Keyword.put(action_opts(opts), :browser_session_id, browser_session.id)
    )

    event_kind =
      if verified.effective_status == :verified_success,
        do: :verification_passed,
        else: :verification_failed

    RoomTimeline.append!(
      room,
      event_kind,
      %{
        "invocation_id" => verified.id,
        "failure_code" => verified.failure_code
      },
      Keyword.put(action_opts(opts), :browser_session_id, browser_session.id)
    )

    room = Domain.get_room_by_id!(room.id, read_opts(opts))

    if verified.effective_status == :verified_success do
      Domain.mark_verified!(room, action_opts(opts))

      RoomTimeline.append!(
        room,
        :goal_verified,
        %{"invocation_id" => verified.id},
        action_opts(opts)
      )
    else
      Domain.record_failure!(room, verified.id, action_opts(opts))
    end

    verified
  end

  defp generated_for_invocation(room, arguments, opts) do
    case Keyword.get(opts, :durable_candidate) do
      nil ->
        CandidateGenerator.generate(room.source_markdown, arguments, opts)

      generated ->
        case CandidateGenerator.validate_generated(generated, room.source_markdown, arguments) do
          :ok -> {:ok, generated}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp apply_and_verify_locked!(invocation, revision, generated, opts) do
    case Ash.transact(
           [Room, BrowserSession, Invocation, Patchbay.Patchbay.Verification],
           fn ->
             room = lock_room!(invocation.room_id, opts)
             browser_session = lock_browser_session!(invocation.browser_session_id, opts)
             revision = lock_revision!(revision.id, opts)
             ensure_current_revision!(room, browser_session, revision)
             ensure_apply_session_current!(room, browser_session, revision)
             room = Domain.apply_candidate!(room, generated.candidate_markdown, action_opts(opts))

             verify_and_update_room!(
               invocation,
               room,
               browser_session,
               Keyword.put(opts, :post_state, visible_state(room))
             )
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, verified} -> verified
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
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
      "fallback_reason" => generated.fallback_reason
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

  defp desired_revision!(room, opts) do
    case Domain.list_tool_revisions!(
           Keyword.put(read_opts(opts), :query,
             filter: [
               room_id: room.id,
               generation: room.desired_tool_generation,
               status: :desired
             ],
             limit: 1
           )
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
         existing.tool_revision_id != revision.id or
         existing.arguments_sha256 != Digest.arguments_sha256(arguments) do
      raise ArgumentError, "request UUID is already bound to different invocation evidence"
    end
  end

  defp create_or_replay!(
         attrs,
         request_uuid,
         room,
         browser_session,
         revision,
         arguments,
         action_opts,
         opts
       ) do
    {:new, Domain.record_invocation!(attrs, action_opts)}
  rescue
    error in Ash.Error.Invalid ->
      case find_by_request_uuid(request_uuid, opts) do
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

  defp durable_candidate!(invocation, room) do
    candidate = invocation.generated_candidate
    candidate_sha256 = invocation.generated_candidate_sha256
    generation_key = invocation.generation_key
    provenance = fetch(invocation.handler_result, :candidate_provenance)

    generated = %{
      candidate_markdown: candidate,
      candidate_sha256: candidate_sha256,
      generation_key: generation_key,
      input_sha256: fetch(provenance, :input_sha256),
      cache_variant: fetch(provenance, :cache_variant),
      change_summary: fetch(invocation.handler_result, :change_summary) || [],
      warnings: fetch(invocation.handler_result, :warnings) || [],
      model: fetch(provenance, :model),
      model_response_id: fetch(provenance, :model_response_id),
      prompt_version: fetch(provenance, :prompt_version),
      fallback_used: fetch(provenance, :fallback_used),
      fallback_reason: fetch(provenance, :fallback_reason)
    }

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
        raise ArgumentError, "instructions must be a non-empty string of at most 1000 bytes"

      true ->
        :ok
    end
  end

  defp validate_arguments!(_schema, _arguments),
    do: raise(ArgumentError, "tool input schema is invalid")

  defp valid_instruction?(arguments) do
    value = Map.get(arguments, "instructions", Map.get(arguments, :instructions))
    is_binary(value) and String.trim(value) != "" and byte_size(value) <= 1_000
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

  defp find_by_request_uuid(request_uuid, opts) do
    Domain.get_invocation_by_request_uuid!(request_uuid, read_opts(opts))
  rescue
    _error in [Ash.Error.Query.NotFound, Ash.Error.Invalid] -> nil
  end

  defp load_invocation!(%Invocation{} = invocation, opts),
    do: Domain.get_invocation!(invocation.id, read_opts(opts))

  defp load_invocation!(id, opts), do: Domain.get_invocation!(id, read_opts(opts))

  defp lock_room!(id, opts) do
    Room
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp lock_browser_session!(id, opts) do
    BrowserSession
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

  defp action_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

  defp query_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

  defp execution_opts(opts),
    do:
      opts
      |> read_opts()
      |> Keyword.drop([:actor, :tenant, :authorize?, :scope, :query])

  defp read_opts(opts),
    do:
      Keyword.drop(opts, [
        :query,
        :post_state,
        :fallback,
        :generator,
        :request,
        :api_key,
        :model,
        :request_uuid,
        :durable_candidate
      ])
end
