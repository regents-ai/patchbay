defmodule PatchbayWeb.WebMCP.RoomLive.BrowserProtocol do
  @moduledoc """
  The WebMCP wire for one room: what the browser's island says to this page, and
  what the page says back to it.

  Nothing here touches the socket or writes anything down. Every function either
  reads a value out of what the browser sent and says whether it is usable, or
  builds the answer Patchbay hands back for a tool call. Deciding what to do
  about any of it belongs to the LiveView.
  """

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{BrowserSession, Digest, Invocation, Verification}

  @doc "Whether an event names this room, or names no room at all."
  @spec valid_room_event?(map(), Patchbay.Patchbay.Room.t()) :: :ok | {:error, String.t()}
  def valid_room_event?(params, room) do
    room_id = room.id

    case Map.get(params, "room_id") do
      nil -> :ok
      ^room_id -> :ok
      _ -> {:error, "event belongs to another room"}
    end
  end

  @doc "The identity a browser gives itself, or a fresh one if it has none yet."
  @spec client_instance_id(map()) :: {:ok, Ash.UUID.t()} | {:error, String.t()}
  def client_instance_id(params) do
    case Map.get(params, "client_instance_id") do
      id when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, "client_instance_id must be a UUID"}
        end

      nil ->
        {:ok, Ash.UUID.generate()}

      _ ->
        {:error, "client_instance_id must be a UUID"}
    end
  end

  @doc "The browser fingerprint an island reports, or a stand-in for one it withheld."
  @spec user_agent_digest(map()) :: String.t()
  def user_agent_digest(params) do
    case Map.get(params, "user_agent_digest") do
      digest when is_binary(digest) and byte_size(digest) == 64 -> digest
      _ -> Digest.sha256("unknown-browser")
    end
  end

  @doc "The registry a browser reports, in the shape `BrowserSession.observe` accepts."
  @spec observed_registry(
          BrowserSession.t(),
          :reconciled | :toolchange,
          map(),
          Patchbay.Patchbay.Room.t()
        ) ::
          map()
  def observed_registry(browser_session, observation, params, room) do
    registry = %{
      webmcp_supported: true,
      desired_generation: room.desired_tool_generation,
      observed_generation: Map.get(params, "observed_generation"),
      observed_tool_names: Map.get(params, "observed_tool_names") || [],
      observed_contracts: Map.get(params, "observed_contracts") || %{},
      last_seen_at: DateTime.utc_now()
    }

    # A toolchange is one registration arriving, so the page counts it. A
    # reconciliation is the whole registry read back and counts nothing.
    case observation do
      :toolchange -> Map.put(registry, :toolchange_count, browser_session.toolchange_count + 1)
      :reconciled -> registry
    end
  end

  @doc "What the timeline records about a registry the browser has just reported."
  @spec registry_payload(BrowserSession.t()) :: map()
  def registry_payload(browser_session) do
    %{
      "generation" => browser_session.observed_generation,
      "tool_names" => browser_session.observed_tool_names,
      "contracts" => browser_session.observed_contracts
    }
  end

  @doc "What the timeline records about a single tool coming or going."
  @spec lifecycle_payload(map()) :: {:ok, map()} | {:error, String.t()}
  def lifecycle_payload(params) do
    name = Map.get(params, "tool_name")
    generation = Map.get(params, "generation")
    digest = Map.get(params, "contract_sha256")

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "tool_name is required"}

      not is_integer(generation) or generation < 1 ->
        {:error, "generation must be positive"}

      not is_binary(digest) or byte_size(digest) != 64 ->
        {:error, "contract digest is invalid"}

      true ->
        {:ok,
         %{
           "tool_name" => name,
           "generation" => generation,
           "contract_sha256" => digest
         }}
    end
  end

  @doc "Whether the tool a browser says it called is the one the room is offering."
  @spec invocation_revision_matches?(map(), Patchbay.Patchbay.ToolRevision.t()) ::
          :ok | {:error, String.t()}
  def invocation_revision_matches?(params, revision) do
    if Map.get(params, "tool_name") == revision.name and
         Map.get(params, "contract_sha256") == revision.contract_sha256 do
      :ok
    else
      {:error, "invoked tool name and contract must match the current desired revision"}
    end
  end

  @doc "Whether a call, or an event about one, belongs to the room's current lifecycle."
  @spec invocation_epoch_matches?(Invocation.t() | map(), Patchbay.Patchbay.Room.t()) ::
          :ok | {:error, String.t()}
  def invocation_epoch_matches?(%Invocation{invocation_epoch: epoch}, room) do
    if epoch == room.invocation_epoch,
      do: :ok,
      else: {:error, "invocation belongs to an earlier room lifecycle"}
  end

  def invocation_epoch_matches?(params, room) do
    case Map.get(params, "invocation_epoch") do
      nil when room.invocation_epoch == 0 -> :ok
      epoch when epoch == room.invocation_epoch -> :ok
      _ -> {:error, "invocation belongs to an earlier room lifecycle"}
    end
  end

  @doc "Whether the browser reporting on a call is the browser that made it."
  @spec invocation_browser_session_matches?(Invocation.t(), BrowserSession.t()) ::
          :ok | {:error, String.t()}
  def invocation_browser_session_matches?(
        %Invocation{browser_session_id: invocation_session_id},
        %BrowserSession{id: browser_session_id}
      )
      when invocation_session_id == browser_session_id,
      do: :ok

  def invocation_browser_session_matches?(_invocation, _browser_session),
    do: {:error, "post-state observation must come from the invocation browser session"}

  @doc "Whether a browser session is still open."
  @spec browser_session_connected?(BrowserSession.t()) :: :ok | {:error, String.t()}
  def browser_session_connected?(%BrowserSession{disconnected_at: nil}), do: :ok

  def browser_session_connected?(_browser_session),
    do: {:error, "browser session is disconnected"}

  @doc "The arguments a browser passed to a tool."
  @spec invocation_arguments(map()) :: {:ok, map()} | {:error, String.t()}
  def invocation_arguments(params) do
    arguments = Map.get(params, "arguments") || %{}

    if is_map(arguments),
      do: {:ok, arguments},
      else: {:error, "invocation arguments must be an object"}
  end

  @doc "The visible state a browser reports after a call."
  @spec post_state(map()) :: {:ok, map()} | {:error, String.t()}
  def post_state(params) do
    state = Map.get(params, "post_state") || %{}
    if is_map(state), do: {:ok, state}, else: {:error, "post_state must be an object"}
  end

  @doc """
  The visible state as the page itself sees it, for the owner's Verify button:
  the same shape a browser would have reported.
  """
  @spec post_state_from_assigns(map()) :: map()
  def post_state_from_assigns(assigns) do
    %{
      "ui_revision" => assigns.room.ui_revision,
      "source" => %{"present" => true, "sha256" => assigns.room.source_sha256},
      "candidate" => %{
        "present" => is_binary(assigns.room.candidate_markdown),
        "sha256" => assigns.room.candidate_sha256
      }
    }
  end

  @doc "Everything Patchbay says back about one tool call."
  @spec invocation_reply(
          Invocation.t(),
          Patchbay.Patchbay.ToolRevision.t(),
          Patchbay.Patchbay.Room.t()
        ) ::
          map()
  def invocation_reply(invocation, revision, room) do
    %{
      "invocation_id" => invocation.id,
      "effective_status" => to_string(invocation.effective_status),
      "failure_code" => if(invocation.failure_code, do: to_string(invocation.failure_code)),
      "handler_reported_success" => invocation.handler_reported_success,
      "handler_result" => invocation.handler_result,
      "patchbay_receipt" => invocation.receipt,
      # The same receipt again, under the name of the thing to do with it, so an
      # agent reading this result cannot miss the one value a report needs.
      "report_this_call" => %{"receipt" => invocation.receipt},
      "patchbay_verification" => verification_reply(invocation),
      "next_action" => invocation_next_action(invocation),
      "expected_ui_revision" => room.ui_revision,
      "ui_commit_required" => revision.handler_adapter == :apply_candidate_to_editor
    }
  end

  defp verification_reply(invocation) do
    case Domain.get_invocation_verification(invocation.id, not_found_error?: false) do
      {:ok, %Verification{} = verification} -> verification_payload(verification)
      {:ok, nil} -> nil
    end
  end

  defp verification_payload(verification) do
    %{
      "passed" => verification.passed,
      "failure_code" => if(verification.failure_code, do: to_string(verification.failure_code)),
      "checks" => verification.checks,
      "expected" => verification.expected_state,
      "observed" => verification.observed_state
    }
  end

  defp invocation_next_action(%Invocation{effective_status: :verified_failure}),
    do: "Call report_tool_problem with receipt set to the patchbay_receipt value in this result."

  defp invocation_next_action(%Invocation{effective_status: :verified_success}),
    do: "The goal is verified; nothing more to do."

  defp invocation_next_action(_invocation), do: "Wait for visible-state verification."

  @doc "One tool as the browser needs to register it."
  @spec revision_payload(Patchbay.Patchbay.ToolRevision.t()) :: map()
  def revision_payload(revision) do
    %{
      "id" => revision.id,
      "name" => revision.name,
      "title" => revision.title,
      "description" => revision.description,
      "input_schema" => revision.input_schema,
      "annotations" => revision.annotations,
      "handler_adapter" => to_string(revision.handler_adapter),
      "output_contract" => revision.output_contract,
      "postcondition_set" => to_string(revision.postcondition_set),
      "contract_sha256" => revision.contract_sha256,
      "generation" => revision.generation
    }
  end

  @doc """
  The sentence a failure is shown as, to the tool that asked and to the person
  watching. A domain error carries the sentence the domain wrote inside the
  class that wraps it, so that sentence is what comes out.
  """
  @spec readable_error(term()) :: String.t()
  def readable_error(%{__exception__: true, errors: [error | _]}), do: readable_error(error)

  def readable_error(%{__exception__: true, message: message}) when is_binary(message),
    do: message

  def readable_error(%{__exception__: true} = error), do: Exception.message(error)
  def readable_error({:shutdown, reason}), do: readable_error(reason)
  def readable_error(reason) when is_binary(reason), do: reason
  def readable_error(reason), do: inspect(reason)
end
