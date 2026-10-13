defmodule PatchbayWeb.Telemetry do
  @moduledoc """
  The site's measurements, as `:telemetry` events: the list the developer
  dashboard draws (`metrics/0`), and their Prometheus export on the private
  metrics listener (`PatchbayWeb.Metrics`), which Fly Sentinel's site watch
  reads. The export keeps the names every Regent site shares: Ecto's
  `[:patchbay, :repo, :query]` (`queue_time` is the wait for a connection),
  each background job's outcome and time from Oban's own events, each
  question asked of a model (`[:patchbay, :model_call, :stop]`) by outcome
  with its tokens and what OpenRouter charged, and the engine's memory, run
  queues and process counts from telemetry_poller's default poller.

  Beside them are Patchbay's own three: the day's readings of posts reaching
  half their limit, each post refused because the limit is reached
  (`Patchbay.Assist.ModelCalls`), and each post turned away whose words
  were not kept because the day's count of them was reached
  (`Patchbay.Forum.PostingCheck`).
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core,
       metrics: prometheus_metrics(), name: prometheus_reporter(), start_async: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def prometheus_reporter, do: :patchbay_prometheus

  # No tag here ever holds a wallet, an account or anything a caller wrote:
  # only queue and worker names and the fixed outcomes.
  defp prometheus_metrics do
    [
      distribution("health.db_queue.seconds",
        event_name: [:patchbay, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        description: "Seconds a query waited for a database connection",
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
      ),
      counter("patchbay.jobs.finished.total",
        event_name: [:oban, :job, :stop],
        tags: [:queue, :worker, :state],
        description: "Job runs that ended done, cancelled or snoozed"
      ),
      counter("patchbay.jobs.failed.total",
        event_name: [:oban, :job, :exception],
        tags: [:queue, :worker, :state],
        description: "Job runs that failed; state says whether the job will retry"
      ),
      distribution("patchbay.jobs.duration.seconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:queue, :worker],
        reporter_options: [buckets: [0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60]]
      ),
      counter("patchbay.jev.questions.total",
        event_name: [:patchbay, :model_call, :stop],
        tags: [:outcome],
        description: "Questions asked of a model, by outcome"
      ),
      sum("patchbay.jev.input_tokens.total",
        event_name: [:patchbay, :model_call, :stop],
        measurement: :prompt_tokens,
        description: "Input tokens the questions were billed for"
      ),
      sum("patchbay.jev.output_tokens.total",
        event_name: [:patchbay, :model_call, :stop],
        measurement: :completion_tokens,
        description: "Output tokens the questions were billed for"
      ),
      # A Prometheus sum adds whole numbers only, so the dollars are a histogram;
      # its `_sum` series is the running total.
      distribution("patchbay.jev.cost.usd",
        event_name: [:patchbay, :model_call, :stop],
        measurement: :cost_usd,
        description: "US dollars OpenRouter charged per question",
        reporter_options: [buckets: [0.00001, 0.0001, 0.001, 0.01, 0.1]]
      ),
      counter("patchbay.post_readings.half_spent.total",
        event_name: [:patchbay, :post_readings, :half_spent],
        description: "Times the day's readings of posts reached half their limit"
      ),
      counter("patchbay.post_readings.day_full.total",
        event_name: [:patchbay, :post_readings, :day_full],
        description: "Posts refused because the day's readings were spent"
      ),
      counter("patchbay.post_readings.words_not_kept.total",
        event_name: [:patchbay, :post_readings, :words_not_kept],
        description: "Posts turned away past the day's count of kept words"
      ),
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

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {PatchbayWeb, :count_users, []}
    ]
  end
end
