defmodule Patchbay.Patchbay.Telemetry do
  @max_metadata_bytes 128

  @moduledoc """
  Named emitters for the ten Patchbay observability events in SPEC section 23.

  Every emitter funnels through one sanitizer, so a handler can only ever see
  numbers, identifiers, digests, booleans, and atoms. Skill markdown, model
  output, arguments, and handler bodies cannot reach telemetry: each event
  carries a fixed allow-list of metadata keys, non-numeric measurements are
  dropped, and any other value — including a binary longer than
  #{@max_metadata_bytes} bytes — becomes `:unavailable` rather than being
  truncated into a partial leak.
  """

  @webmcp_metadata [:room_id, :browser_session_id, :tool_generation, :contract_sha256]
  @invocation_metadata [
    :room_id,
    :browser_session_id,
    :invocation_id,
    :tool_generation,
    :tool_name,
    :contract_sha256,
    :arguments_sha256
  ]
  @handler_stop_metadata @invocation_metadata ++ [:fallback_used, :failure_code, :receipt]
  @verification_metadata [:room_id, :invocation_id, :passed, :failure_code]
  @repair_model_metadata [:room_id, :invocation_id, :fallback_used]
  @canary_metadata [:room_id, :invocation_id, :tool_revision_id, :passed, :failure_code]
  @publication_metadata [:room_id, :tool_revision_id, :tool_generation]
  @goal_metadata [:room_id, :invocation_id, :tool_generation]

  @events [
    [:patchbay, :webmcp, :registered],
    [:patchbay, :webmcp, :unregistered],
    [:patchbay, :webmcp, :toolchange],
    [:patchbay, :invocation, :start],
    [:patchbay, :invocation, :handler_stop],
    [:patchbay, :verification, :stop],
    [:patchbay, :repair, :model_stop],
    [:patchbay, :repair, :canary_stop],
    [:patchbay, :publication, :stop],
    [:patchbay, :goal, :verified]
  ]

  @doc "The exact event names Patchbay emits."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "A browser session registered a Patchbay tool revision."
  @spec webmcp_registered(map()) :: :ok
  def webmcp_registered(metadata),
    do: emit([:patchbay, :webmcp, :registered], @webmcp_metadata, %{count: 1}, metadata)

  @doc "A browser session unregistered a Patchbay tool revision."
  @spec webmcp_unregistered(map()) :: :ok
  def webmcp_unregistered(metadata),
    do: emit([:patchbay, :webmcp, :unregistered], @webmcp_metadata, %{count: 1}, metadata)

  @doc "The page observed a WebMCP toolchange notification."
  @spec webmcp_toolchange(map()) :: :ok
  def webmcp_toolchange(metadata),
    do: emit([:patchbay, :webmcp, :toolchange], @webmcp_metadata, %{count: 1}, metadata)

  @doc "A durable invocation started executing its handler."
  @spec invocation_start(map()) :: :ok
  def invocation_start(metadata) do
    emit(
      [:patchbay, :invocation, :start],
      @invocation_metadata,
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  The handler finished. `duration` is native time; `input_tokens` and
  `output_tokens` come from the OpenAI usage map when the call was live.
  """
  @spec invocation_handler_stop(map(), map()) :: :ok
  def invocation_handler_stop(measurements, metadata),
    do:
      emit(
        [:patchbay, :invocation, :handler_stop],
        @handler_stop_metadata,
        measurements,
        metadata
      )

  @doc """
  Server-derived postcondition verification finished. `ui_commit_ms` is the
  time between the handler returning and the visible state being verified.
  """
  @spec verification_stop(map(), map()) :: :ok
  def verification_stop(measurements, metadata),
    do: emit([:patchbay, :verification, :stop], @verification_metadata, measurements, metadata)

  @doc "The repair plan came back from the model. `duration` is the OpenAI latency."
  @spec repair_model_stop(map(), map()) :: :ok
  def repair_model_stop(measurements, metadata),
    do: emit([:patchbay, :repair, :model_stop], @repair_model_metadata, measurements, metadata)

  @doc "The deterministic canary finished for a candidate revision."
  @spec repair_canary_stop(map(), map()) :: :ok
  def repair_canary_stop(measurements, metadata),
    do: emit([:patchbay, :repair, :canary_stop], @canary_metadata, measurements, metadata)

  @doc "A tool revision became the room's desired revision."
  @spec publication_stop(map(), map()) :: :ok
  def publication_stop(measurements, metadata),
    do: emit([:patchbay, :publication, :stop], @publication_metadata, measurements, metadata)

  @doc "The room's goal was verified from server-owned evidence."
  @spec goal_verified(map()) :: :ok
  def goal_verified(metadata),
    do: emit([:patchbay, :goal, :verified], @goal_metadata, %{count: 1}, metadata)

  defp emit(event, metadata_keys, measurements, metadata) do
    :telemetry.execute(
      event,
      sanitize_measurements(measurements),
      sanitize_metadata(metadata_keys, metadata)
    )
  end

  defp sanitize_measurements(measurements) when is_map(measurements) do
    for {key, value} <- measurements,
        is_atom(key) and is_number(value),
        into: %{},
        do: {key, value}
  end

  defp sanitize_measurements(_measurements), do: %{}

  defp sanitize_metadata(keys, metadata) when is_map(metadata) do
    Map.new(keys, fn key -> {key, safe_value(Map.get(metadata, key))} end)
  end

  defp sanitize_metadata(keys, _metadata), do: Map.new(keys, &{&1, nil})

  defp safe_value(value) when is_atom(value) or is_number(value), do: value

  defp safe_value(value) when is_binary(value) and byte_size(value) <= @max_metadata_bytes,
    do: value

  defp safe_value(_value), do: :unavailable
end
