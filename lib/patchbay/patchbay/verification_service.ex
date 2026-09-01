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
    Verification
  }

  require Ash.Query

  @spec verify_invocation!(Invocation.t() | binary(), map(), keyword()) :: Invocation.t()
  def verify_invocation!(invocation_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    case Ash.transact(
           [Room, Invocation, Patchbay.Patchbay.Verification],
           fn ->
             invocation = load_invocation!(invocation_or_id, opts)
             room = lock_room!(invocation.room_id, opts)
             invocation = lock_invocation!(invocation.id, opts)

             if invocation.invocation_epoch != room.invocation_epoch do
               raise ArgumentError, "invocation belongs to an earlier room lifecycle"
             end

             if invocation.effective_status in [:cancelled, :errored] do
               raise ArgumentError, "invocation is no longer awaiting visible proof"
             end

             case existing_verification(invocation.id, opts) do
               %Verification{} = verification ->
                 result = durable_result!(verification)

                 persist_invocation_result!(
                   invocation,
                   result,
                   verification.inserted_at || DateTime.utc_now(),
                   opts
                 )

               nil ->
                 post_state = fetch(attrs, :post_state, %{})
                 result = derive_result_for_room(invocation, room, post_state, opts)

                 verification = persist_verification!(invocation, result, opts)

                 persist_invocation_result!(
                   invocation,
                   result,
                   verification.inserted_at || DateTime.utc_now(),
                   opts
                 )
             end
           end,
           Keyword.take(opts, [:timeout])
         ) do
      {:ok, invocation} -> invocation
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  @doc false
  @spec derive_result(Invocation.t(), map(), keyword()) :: map()
  def derive_result(%Invocation{} = invocation, post_state, opts \\ []) do
    room = Domain.get_room_by_id!(invocation.room_id, read_opts(opts))
    derive_result_for_room(invocation, room, post_state, opts)
  end

  defp derive_result_for_room(%Invocation{} = invocation, room, post_state, opts)
       when is_map(post_state) do
    tool_revision = Domain.get_tool_revision!(invocation.tool_revision_id, read_opts(opts))
    browser_session = Domain.get_browser_session!(invocation.browser_session_id, read_opts(opts))
    active_revision = active_revision(room, opts)

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

  defp derive_result_for_room(_invocation, _room, _post_state, _opts), do: invalid_result()

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

  defp active_revision(room, opts) do
    Domain.list_tool_revisions!(
      Keyword.put(read_opts(opts), :query,
        filter: [
          room_id: room.id,
          status: :desired,
          generation: room.desired_tool_generation
        ],
        limit: 1
      )
    )
    |> List.first()
  end

  defp persist_invocation_result!(invocation, result, verified_at, opts) do
    changeset =
      Ash.Changeset.for_update(
        invocation,
        :record_verification,
        %{
          post_state: result.observed_state,
          failure_code: result.failure_code,
          verified_at: verified_at
        },
        changeset_opts(opts)
      )

    changeset
    |> Ash.Changeset.set_context(%{trusted_verification_result: result})
    |> Ash.update!()
  end

  defp persist_verification!(invocation, result, opts) do
    attrs = %{
      room_id: invocation.room_id,
      invocation_id: invocation.id,
      checks: result.checks,
      passed: result.passed,
      failure_code: result.failure_code,
      expected_state: result.expected_state,
      observed_state: result.observed_state
    }

    Ash.Changeset.for_create(
      Patchbay.Patchbay.Verification,
      :record_verification,
      attrs,
      changeset_opts(opts)
    )
    |> Ash.create!()
  end

  defp existing_verification(invocation_id, opts) do
    query =
      Verification
      |> Ash.Query.for_read(:read, %{}, query_opts(opts))
      |> Ash.Query.filter(invocation_id: invocation_id)
      |> Ash.Query.lock(:for_update)

    case Ash.read!(query, execution_opts(opts)) do
      [verification | _] -> verification
      [] -> nil
    end
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

  defp load_invocation!(%Invocation{} = invocation, opts),
    do: Domain.get_invocation!(invocation.id, read_opts(opts))

  defp load_invocation!(invocation_id, opts),
    do: Domain.get_invocation!(invocation_id, read_opts(opts))

  defp lock_invocation!(invocation_id, opts) do
    Invocation
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: invocation_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp lock_room!(room_id, opts) do
    Room
    |> Ash.Query.for_read(:read, %{}, query_opts(opts))
    |> Ash.Query.filter(id: room_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(execution_opts(opts))
  end

  defp query_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?, :scope])

  defp read_opts(opts), do: Keyword.drop(opts, [:query, :post_state, :timeout])

  defp execution_opts(opts),
    do: Keyword.drop(opts, [:actor, :tenant, :authorize?, :scope, :query, :post_state, :timeout])

  defp changeset_opts(opts) do
    opts
    |> query_opts()
    |> Keyword.put(:domain, Domain)
  end

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
