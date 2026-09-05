defmodule Patchbay.Patchbay.TelemetryLogger do
  @moduledoc """
  Writes one `[webmcp]` log line per Patchbay telemetry event.

  The deployed room is observed through `fly logs`, so every event in
  `Patchbay.Patchbay.Telemetry.events/0` becomes exactly one `:info` line with a
  fixed prefix, the dotted event name, and a fixed column order:

      [webmcp] invocation.handler_stop room=<uuid> session=<uuid> invocation=<uuid> generation=1 tool=uplift_current_skill_v1 contract=<sha256> args=<sha256> outcome=success failure_code=- duration_ms=42 fallback_used=false receipt=<receipt>

  Each column is read by name from the sanitized metadata the emitter already
  allow-listed, never from the metadata map as a whole, so arguments, handler
  bodies, candidate markdown, and model output cannot reach the log even if a
  future caller passes them. A column with no value for that event prints `-`.
  """

  require Logger

  alias Patchbay.Patchbay.Telemetry

  @handler_id "patchbay-webmcp-log"
  @prefix "[webmcp]"

  # The column order per event is fixed so operators can grep and diff lines.
  @columns %{
    [:patchbay, :webmcp, :registered] => [:room, :session, :generation, :contract],
    [:patchbay, :webmcp, :unregistered] => [:room, :session, :generation, :contract],
    [:patchbay, :webmcp, :toolchange] => [:room, :session, :generation, :contract],
    [:patchbay, :invocation, :start] => [
      :room,
      :session,
      :invocation,
      :generation,
      :tool,
      :contract,
      :args
    ],
    [:patchbay, :invocation, :handler_stop] => [
      :room,
      :session,
      :invocation,
      :generation,
      :tool,
      :contract,
      :args,
      :outcome,
      :failure_code,
      :duration_ms,
      :fallback_used,
      :receipt
    ],
    [:patchbay, :verification, :stop] => [
      :room,
      :invocation,
      :outcome,
      :failure_code,
      :duration_ms
    ],
    [:patchbay, :repair, :model_stop] => [:room, :invocation, :duration_ms, :fallback_used],
    [:patchbay, :repair, :canary_stop] => [
      :room,
      :invocation,
      :revision,
      :outcome,
      :failure_code,
      :duration_ms
    ],
    [:patchbay, :publication, :stop] => [:room, :revision, :generation, :duration_ms],
    [:patchbay, :goal, :verified] => [:room, :invocation, :generation],
    [:patchbay, :agent, :repair_start] => [:room, :report, :attempt],
    [:patchbay, :agent, :repair_stop] => [
      :room,
      :report,
      :attempt,
      :outcome,
      :contract,
      :duration_ms
    ]
  }

  @doc "The column names logged for one event, in the order they are printed."
  @spec columns(:telemetry.event_name()) :: [atom()] | nil
  def columns(event), do: Map.get(@columns, event)

  @doc """
  Attaches the log handler to every Patchbay event. Safe to call again: a
  repeated attach in the same VM is a no-op.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           @handler_id,
           Telemetry.events(),
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    case Map.fetch(@columns, event) do
      {:ok, columns} ->
        Logger.info("#{@prefix} #{event_name(event)} #{fields(columns, measurements, metadata)}")

      :error ->
        :ok
    end
  end

  defp fields(columns, measurements, metadata) do
    Enum.map_join(columns, " ", fn column ->
      "#{column}=#{format(value(column, measurements, metadata))}"
    end)
  end

  defp value(:room, _measurements, metadata), do: metadata[:room_id]
  defp value(:session, _measurements, metadata), do: metadata[:browser_session_id]
  defp value(:invocation, _measurements, metadata), do: metadata[:invocation_id]
  defp value(:generation, _measurements, metadata), do: metadata[:tool_generation]
  defp value(:contract, _measurements, metadata), do: metadata[:contract_sha256]
  defp value(:tool, _measurements, metadata), do: metadata[:tool_name]
  defp value(:args, _measurements, metadata), do: metadata[:arguments_sha256]
  defp value(:revision, _measurements, metadata), do: metadata[:tool_revision_id]
  defp value(:report, _measurements, metadata), do: metadata[:report_id]
  defp value(:attempt, _measurements, metadata), do: metadata[:attempt_id]
  defp value(:failure_code, _measurements, metadata), do: metadata[:failure_code]
  defp value(:fallback_used, _measurements, metadata), do: metadata[:fallback_used]
  defp value(:receipt, _measurements, metadata), do: metadata[:receipt]
  defp value(:outcome, _measurements, metadata), do: outcome(metadata)
  defp value(:duration_ms, measurements, _metadata), do: duration_ms(measurements)

  # An event that names its own outcome says it plainly; the rest are read from
  # whether their check passed.
  defp outcome(%{outcome: outcome}) when is_atom(outcome) and not is_nil(outcome), do: outcome

  defp outcome(%{passed: passed}) when is_boolean(passed),
    do: if(passed, do: :success, else: :failure)

  defp outcome(%{passed: _passed}), do: nil
  defp outcome(%{failure_code: nil}), do: :success
  defp outcome(%{failure_code: _failure_code}), do: :failure
  defp outcome(_metadata), do: nil

  defp duration_ms(%{duration: duration}) when is_integer(duration),
    do: System.convert_time_unit(duration, :native, :millisecond)

  defp duration_ms(_measurements), do: nil

  defp event_name([:patchbay | rest]), do: Enum.map_join(rest, ".", &Atom.to_string/1)

  defp format(nil), do: "-"
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value) when is_integer(value), do: Integer.to_string(value)
  defp format(value) when is_float(value), do: Float.to_string(value)
  defp format(value) when is_binary(value), do: value
end
