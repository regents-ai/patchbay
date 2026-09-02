defmodule Patchbay.Patchbay.VerificationService do
  @moduledoc """
  Runs postcondition verification from server-owned evidence.

  Browser observations are inputs to the verifier, not proof of success. The
  service loads the invocation's room, active tool revision, and browser
  session, derives the independent baselines, and persists only the verifier
  result.
  """

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    BrowserSession,
    Digest,
    Invocation,
    PostconditionVerifier,
    Room,
    Telemetry,
    Verification
  }

  require Ash.Query

  @spec verify_invocation!(Invocation.t() | binary(), map(), keyword()) :: Invocation.t()
  def verify_invocation!(invocation_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    started_at = System.monotonic_time()

    case Ash.transact(
           [Room, Invocation, Patchbay.Patchbay.Verification],
           fn -> verify_locked!(invocation_or_id, attrs) end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, invocation} ->
        emit_verification_stop(started_at, invocation)
        invocation

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp verify_locked!(invocation_or_id, attrs) do
    invocation = load_invocation!(invocation_or_id)
    room = Domain.get_room_for_update!(invocation.room_id, load: :desired_tool_revision)
    invocation = Domain.get_invocation_for_update!(invocation.id)

    ensure_current_epoch!(invocation, room)
    ensure_awaiting_proof!(invocation)

    case existing_verification(invocation.id) do
      %Verification{} = verification ->
        persist_invocation_result!(
          invocation,
          durable_result!(verification),
          verification.inserted_at || DateTime.utc_now()
        )

      nil ->
        result = derive_result_for_room(invocation, room, fetch(attrs, :post_state, %{}))
        verification = persist_verification!(invocation, result)

        persist_invocation_result!(
          invocation,
          result,
          verification.inserted_at || DateTime.utc_now()
        )
    end
  end

  defp ensure_current_epoch!(invocation, room) do
    if invocation.invocation_epoch != room.invocation_epoch do
      raise ArgumentError, "invocation belongs to an earlier room lifecycle"
    end
  end

  defp ensure_awaiting_proof!(invocation) do
    if invocation.effective_status in [:cancelled, :errored] do
      raise ArgumentError, "invocation is no longer awaiting visible proof"
    end
  end

  defp emit_verification_stop(started_at, invocation) do
    Telemetry.verification_stop(
      %{
        duration: System.monotonic_time() - started_at,
        ui_commit_ms: ui_commit_ms(invocation)
      },
      %{
        room_id: invocation.room_id,
        invocation_id: invocation.id,
        passed: invocation.effective_status == :verified_success,
        failure_code: invocation.failure_code
      }
    )
  end

  # The gap between the handler returning and the visible state being verified
  # is the only UI commit latency the invocation record already carries.
  defp ui_commit_ms(%Invocation{
         handler_returned_at: %DateTime{} = returned,
         verified_at: %DateTime{} = verified
       }),
       do: DateTime.diff(verified, returned, :millisecond)

  defp ui_commit_ms(_invocation), do: nil

  @doc false
  @spec derive_result(Invocation.t(), map()) :: map()
  def derive_result(%Invocation{} = invocation, post_state) do
    room = Domain.get_room_by_id!(invocation.room_id, load: :desired_tool_revision)
    derive_result_for_room(invocation, room, post_state)
  end

  defp derive_result_for_room(%Invocation{} = invocation, room, post_state)
       when is_map(post_state) do
    tool_revision = Domain.get_tool_revision!(invocation.tool_revision_id)
    browser_session = Domain.get_browser_session!(invocation.browser_session_id)
    active_revision = room.desired_tool_revision

    if tool_revision.room_id != room.id or browser_session.room_id != room.id do
      raise ArgumentError, "invocation evidence relationships must belong to the same room"
    end

    expected_candidate_sha256 = generated_candidate_sha256(invocation)
    expected_contract_sha256 = active_contract_sha256(invocation, tool_revision, active_revision)
    browser_observation = browser_observation(browser_session, room, active_revision)

    observed_state =
      post_state
      |> Map.put(:tool_contract_sha256, browser_observation.observed_contract_sha256)
      |> Map.put(:browser_session_id, browser_observation.observed_browser_session_id)

    PostconditionVerifier.verify(
      invocation.pre_state,
      observed_state,
      source_markdown: room.source_markdown,
      candidate_markdown: room.candidate_markdown,
      expected_candidate_sha256: expected_candidate_sha256,
      expected_contract_sha256: expected_contract_sha256,
      observed_contract_sha256: browser_observation.observed_contract_sha256,
      expected_browser_session_id: browser_session.id,
      observed_browser_session_id: browser_observation.observed_browser_session_id
    )
  end

  defp derive_result_for_room(_invocation, _room, _post_state), do: invalid_result()

  defp generated_candidate_sha256(%{
         generated_candidate: candidate,
         generated_candidate_sha256: digest
       })
       when is_binary(candidate) and is_binary(digest) do
    if Digest.sha256(candidate) == digest, do: digest
  end

  defp generated_candidate_sha256(_invocation), do: nil

  defp active_contract_sha256(
         invocation,
         %{id: tool_revision_id, contract_sha256: tool_contract_sha256},
         %{id: active_revision_id, contract_sha256: active_contract_sha256}
       )
       when tool_revision_id == active_revision_id and
              invocation.tool_contract_sha256 == tool_contract_sha256 and
              tool_contract_sha256 == active_contract_sha256,
       do: active_contract_sha256

  defp active_contract_sha256(_invocation, _tool_revision, _active_revision), do: nil

  defp browser_observation(%BrowserSession{} = browser_session, room, active_revision) do
    observed_contract_sha256 =
      if active_revision do
        fetch(browser_session.observed_contracts, active_revision.name, nil)
      end

    session_current? =
      is_nil(browser_session.disconnected_at) and
        browser_session.desired_generation == room.desired_tool_generation and
        browser_session.observed_generation == room.desired_tool_generation

    %{
      observed_contract_sha256: observed_contract_sha256,
      observed_browser_session_id: if(session_current?, do: browser_session.id, else: nil)
    }
  end

  defp persist_invocation_result!(invocation, result, verified_at) do
    invocation
    |> Ash.Changeset.for_update(
      :record_verification,
      %{
        post_state: result.observed_state,
        failure_code: result.failure_code,
        verified_at: verified_at
      },
      domain: Domain
    )
    |> Ash.Changeset.set_context(%{trusted_verification_result: result})
    |> Ash.update!()
  end

  defp persist_verification!(invocation, result) do
    attrs = %{
      room_id: invocation.room_id,
      invocation_id: invocation.id,
      checks: result.checks,
      passed: result.passed,
      failure_code: result.failure_code,
      expected_state: result.expected_state,
      observed_state: result.observed_state
    }

    Verification
    |> Ash.Changeset.for_create(:record_verification, attrs, domain: Domain)
    |> Ash.create!()
  end

  defp existing_verification(invocation_id) do
    Verification
    |> Ash.Query.for_read(:for_update)
    |> Ash.Query.filter(invocation_id: invocation_id)
    |> Ash.read!()
    |> List.first()
  end

  defp durable_result!(%Verification{} = verification) do
    result = %{
      passed: verification.passed,
      checks: verification.checks,
      failure_code: verification.failure_code,
      expected_state: verification.expected_state,
      observed_state: verification.observed_state
    }

    if PostconditionVerifier.valid_result?(result) do
      result
    else
      raise ArgumentError, "persisted verification result is invalid"
    end
  end

  defp load_invocation!(%Invocation{} = invocation),
    do: Domain.get_invocation!(invocation.id)

  defp load_invocation!(invocation_id), do: Domain.get_invocation!(invocation_id)

  defp invalid_result do
    %{
      passed: false,
      checks: %{},
      failure_code: :CANDIDATE_EMPTY,
      expected_state: %{},
      observed_state: %{}
    }
  end

  defp fetch(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Enum.find_value(map, default, &matching_key(&1, key))
    end
  end

  defp matching_key({candidate, value}, key)
       when is_atom(candidate) and is_binary(key),
       do: if(Atom.to_string(candidate) == key, do: value)

  defp matching_key({candidate, value}, key)
       when is_binary(candidate) and is_atom(key),
       do: if(candidate == Atom.to_string(key), do: value)

  defp matching_key(_entry, _key), do: nil
end
