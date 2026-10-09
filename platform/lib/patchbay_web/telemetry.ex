defmodule PatchbayWeb.Telemetry do
  @moduledoc """
  The site's measurements and their Prometheus export on the private metrics
  listener (`PatchbayWeb.Metrics`). The engine's memory, run queues and process
  counts come from telemetry_poller's default poller, every 10 seconds
  (`config/config.exs`). `metrics/0` is the development dashboard's list.
  """

  import Telemetry.Metrics

  def child_spec(_arg) do
    TelemetryMetricsPrometheus.Core.child_spec(
      metrics: prometheus_metrics(),
      name: prometheus_reporter(),
      start_async: false
    )
  end

  def prometheus_reporter, do: :patchbay_prometheus

  def prometheus_metrics do
    [
      last_value("vm.memory.total.bytes", event_name: [:vm, :memory], measurement: :total),
      last_value("vm.memory.processes.bytes",
        event_name: [:vm, :memory],
        measurement: :processes
      ),
      last_value("vm.memory.binary.bytes", event_name: [:vm, :memory], measurement: :binary),
      last_value("vm.memory.ets.bytes", event_name: [:vm, :memory], measurement: :ets),
      last_value("vm.memory.code.bytes", event_name: [:vm, :memory], measurement: :code),
      last_value("vm.memory.atom.bytes", event_name: [:vm, :memory], measurement: :atom),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count")
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("patchbay.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("patchbay.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("patchbay.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("patchbay.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("patchbay.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Patchbay Metrics
      #
      # Tags and measurements are limited to the identifiers, digests, counters,
      # and durations the emitters allow, so no Skill content or model output
      # can reach a reporter.
      counter("patchbay.webmcp.registered.count", tags: [:tool_generation]),
      counter("patchbay.webmcp.unregistered.count", tags: [:tool_generation]),
      counter("patchbay.webmcp.toolchange.count", tags: [:tool_generation]),
      summary("patchbay.invocation.start.system_time",
        tags: [:tool_generation],
        unit: {:native, :millisecond}
      ),
      summary("patchbay.invocation.handler_stop.duration",
        tags: [:tool_generation, :sample_used, :failure_code],
        unit: {:native, :millisecond}
      ),
      summary("patchbay.invocation.handler_stop.input_tokens",
        description: "Input tokens billed for the candidate generation"
      ),
      summary("patchbay.invocation.handler_stop.output_tokens",
        description: "Output tokens billed for the candidate generation"
      ),
      summary("patchbay.verification.stop.duration",
        tags: [:passed, :failure_code],
        unit: {:native, :millisecond}
      ),
      summary("patchbay.verification.stop.ui_commit_ms",
        tags: [:passed],
        description: "Time between the handler returning and the visible state being verified"
      ),
      summary("patchbay.repair.model_stop.duration",
        tags: [:sample_used],
        unit: {:native, :millisecond},
        description: "OpenAI latency for the repair plan"
      ),
      summary("patchbay.repair.model_stop.input_tokens",
        description: "Input tokens billed for the repair plan"
      ),
      summary("patchbay.repair.model_stop.output_tokens",
        description: "Output tokens billed for the repair plan"
      ),
      summary("patchbay.repair.canary_stop.duration",
        tags: [:passed, :failure_code],
        unit: {:native, :millisecond}
      ),
      summary("patchbay.publication.stop.duration",
        tags: [:tool_generation],
        unit: {:native, :millisecond}
      ),
      counter("patchbay.goal.verified.count", tags: [:tool_generation]),
      summary("patchbay.model_call.stop.prompt_tokens",
        tags: [:purpose, :outcome],
        description: "Prompt tokens OpenRouter billed for one question"
      ),
      summary("patchbay.model_call.stop.completion_tokens",
        tags: [:purpose, :outcome],
        description: "Completion tokens OpenRouter billed for one question"
      ),
      summary("patchbay.model_call.stop.cost_usd",
        tags: [:purpose, :outcome],
        description: "What OpenRouter said one question cost, in US dollars"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end
end
