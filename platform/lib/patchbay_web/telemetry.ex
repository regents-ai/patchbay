defmodule PatchbayWeb.Telemetry do
  @moduledoc """
  The site's measurements, as `:telemetry` events: the list the developer
  dashboard draws (`metrics/0`), and their Prometheus export on the private
  metrics listener (`PatchbayWeb.Metrics`), which Fly Sentinel's site watch
  reads. The export keeps the names every Regent site shares: Ecto's
  `[:patchbay, :repo, :query]` (`queue_time` is the wait for a connection and
  `total_time` the query's whole time), each request the router sends to a page
  or controller by its route pattern (`[:phoenix, :router_dispatch, :stop]`),
  never by its path,
  each background job's outcome and time from Oban's own events,
  `[:patchbay, :jobs, :oldest_unfinished]` (`age_ms` of the oldest available,
  running or retrying job in each running `queue`, 0 when there is none,
  every ten seconds; a paused queue keeps its jobs waiting on purpose, so it
  is not measured), each question asked of a model
  (`[:patchbay, :model_call, :stop]`) by outcome with its tokens and what
  OpenRouter charged, and the engine's memory, run queues and process counts
  from telemetry_poller's default poller.

  The figures every visitor sees alike (`Patchbay.SharedReading`) report, for
  each kind, how many keys are held, how many have never been read, how long ago
  the oldest was read, each reading that could not be taken and each one refused.

  Beside them are Patchbay's own three: the day's readings of posts reaching
  half their limit, each post refused because the limit is reached
  (`Patchbay.Assist.ModelCalls`), and each post turned away whose words
  were not kept because the day's count of them was reached
  (`Patchbay.Forum.PostingCheck`).

  The reporter, Peep, keeps a fixed set of counters for each series and holds
  no observation between scrapes. It adds each observation to a running total
  as a whole number, so times are measured in whole microseconds and model
  charges in billionths of a dollar, and every total stays exact.
  """

  import Ecto.Query, only: [from: 2]
  import Telemetry.Metrics

  alias PatchbayWeb.Telemetry.Buckets

  require Logger

  @reporter :patchbay_prometheus

  def child_spec(_arg) do
    Peep.child_spec(metrics: prometheus_metrics(), name: @reporter)
  end

  @doc "Every measurement as Prometheus text, as the metrics listener answers it."
  def scrape,
    do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export() |> IO.iodata_to_binary()

  @doc "The poller for the measurements the site takes itself, started after Oban."
  def site_poller,
    do:
      {:telemetry_poller,
       measurements: [
         {Patchbay.SharedReading, :measure, []},
         {__MODULE__, :oldest_unfinished_jobs, []}
       ],
       period: 10_000,
       name: :patchbay_site_poller}

  # The poller drops for good a measurement that raises or exits, and the row
  # would then keep its last number. So whatever stops this tick (a database
  # that cannot answer, a queue too busy to say whether it runs, Oban or the
  # repo restarting) is logged and skipped; the next tick measures again.
  @doc false
  def oldest_unfinished_jobs do
    measure_oldest_unfinished_jobs()
  rescue
    error -> not_measured(Exception.message(error))
  catch
    :exit, reason -> not_measured(Exception.format_exit(reason))
  end

  defp not_measured(why), do: Logger.warning("background job age not measured: #{why}")

  # Only running queues are measured: a paused queue holds its jobs on purpose,
  # and its age would only grow. Where no queue runs (tests), nothing is read.
  defp measure_oldest_unfinished_jobs do
    case for %{queue: queue, paused: false} <- Oban.check_all_queues(), do: queue do
      [] -> :ok
      running -> report_oldest(running)
    end
  end

  defp report_oldest(running) do
    %{prefix: prefix} = Oban.config()

    oldest =
      from(j in Oban.Job,
        where: j.state in ["available", "executing", "retryable"],
        group_by: j.queue,
        select: {j.queue, min(j.inserted_at)}
      )
      # Oban's job table has no Ash resource; this only reads it.
      |> Patchbay.Repo.all(prefix: prefix)
      |> Map.new()

    now = DateTime.utc_now()

    for queue <- running do
      age_ms =
        case oldest[queue] do
          nil -> 0
          inserted_at -> DateTime.diff(now, inserted_at, :millisecond)
        end

      :telemetry.execute([:patchbay, :jobs, :oldest_unfinished], %{age_ms: age_ms}, %{
        queue: queue
      })
    end
  end

  # No tag here ever holds a wallet, an account or anything a caller wrote:
  # only queue and worker names and the fixed outcomes.
  defp prometheus_metrics do
    [
      distribution("health.db_queue.microseconds",
        event_name: [:patchbay, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :microsecond},
        description: "Microseconds a query waited for a database connection",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000] ++
              [1_000_000, 2_500_000, 5_000_000]
        ]
      ),
      distribution("patchbay.repo.query.microseconds",
        event_name: [:patchbay, :repo, :query],
        measurement: :total_time,
        unit: {:native, :microsecond},
        description: "Microseconds each query took, waiting for a connection included",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000] ++
              [1_000_000, 2_500_000, 5_000_000]
        ]
      ),
      distribution("patchbay.request.duration.microseconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:route],
        description: "Microseconds each request took, by its route pattern",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets:
            [5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000] ++
              [2_500_000, 5_000_000, 10_000_000]
        ]
      ),
      last_value("health.job.oldest_age.seconds",
        event_name: [:patchbay, :jobs, :oldest_unfinished],
        measurement: :age_ms,
        unit: {:millisecond, :second},
        tags: [:queue],
        description:
          "Age of the oldest unfinished background job in the queue, counted from when it was added"
      ),
      counter("health.agent_activity_unread.total",
        event_name: [:patchbay, :agents, :activity_unread],
        tags: [:reason],
        description: "Agents' activity reads from the sign-in service that gave no reading"
      ),
      last_value("health.shared_reading.oldest.seconds",
        event_name: [:patchbay, :shared_reading, :kind],
        measurement: :oldest_seconds,
        tags: [:kind],
        description: "Seconds since the oldest shared reading of each kind was read"
      ),
      last_value("health.shared_reading.late.keys",
        event_name: [:patchbay, :shared_reading, :kind],
        measurement: :late,
        tags: [:kind],
        description: "Keys of the kind last read longer ago than the kind's producer should allow"
      ),
      last_value("health.shared_reading.never_read.keys",
        event_name: [:patchbay, :shared_reading, :kind],
        measurement: :never_read,
        tags: [:kind],
        description: "Keys of the kind that have had no reading since the site started"
      ),
      counter("health.shared_reading.degraded.total",
        event_name: [:patchbay, :shared_reading, :degraded],
        tags: [:kind],
        description: "Shared readings that could not be taken"
      ),
      last_value("patchbay.shared_reading.keys",
        event_name: [:patchbay, :shared_reading, :kind],
        measurement: :keys,
        tags: [:kind]
      ),
      last_value("patchbay.shared_reading.table.bytes",
        event_name: [:patchbay, :shared_reading, :table],
        measurement: :bytes
      ),
      counter("patchbay.shared_reading.refused.total",
        event_name: [:patchbay, :shared_reading, :refused],
        tags: [:kind, :reason]
      ),
      counter("patchbay.shared_reading.woken.total",
        event_name: [:patchbay, :shared_reading, :woken],
        tags: [:kind]
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
      distribution("patchbay.jobs.duration.microseconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:queue, :worker],
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets: [
            10_000,
            50_000,
            100_000,
            500_000,
            1_000_000,
            5_000_000,
            15_000_000,
            60_000_000
          ]
        ]
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
      # The dollars are a histogram, so its `_sum` series is the running total.
      # A question reports a float of dollars; billionths keep that total exact.
      distribution("patchbay.jev.cost.nanodollars",
        event_name: [:patchbay, :model_call, :stop],
        measurement: &round(&1.cost_usd * 1_000_000_000),
        description: "Billionths of a US dollar OpenRouter charged per question",
        reporter_options: [
          peep_bucket_calculator: Buckets,
          buckets: [10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]
        ]
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
      # Tags and measurements are limited to the counters and durations the
      # emitters allow, so no post or model output can reach a reporter.
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
