defmodule Patchbay.Assist.Runner do
  @moduledoc """
  Hands each paid assist to its own worker the moment its payment lands, a
  few at a time, and watches each one to its end.

  A run's work is a call or two to a stranger's site and a few questions
  to Jev, none of which may happen twice on a guess, so a worker that dies
  or runs past its time leaves its run marked failed for a person to look
  at rather than started over. The runs left open by a restart are closed
  the same way at boot, by `Patchbay.Assist.Sweep`, before this starts.
  Tests drive `Patchbay.Assist.Work` directly and start no runner.
  """

  use GenServer

  require Logger

  alias Patchbay.Assist
  alias Patchbay.Assist.Run
  alias Patchbay.Assist.Work

  @task_supervisor Patchbay.Assist.TaskSupervisor
  @max_at_once 4
  @deadline_ms :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The supervisor the runner starts each run's worker under."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: @task_supervisor

  @doc """
  Starts work on `run`, or queues it behind the runs under way. Without a
  runner (as in tests) the run stays paid and nothing else happens.
  """
  @spec start(Run.t()) :: :ok
  def start(%Run{id: id}), do: GenServer.cast(__MODULE__, {:start, id})

  @impl true
  def init(:ok), do: {:ok, %{working: %{}, waiting: :queue.new()}}

  @impl true
  def handle_cast({:start, run_id}, state),
    do: {:noreply, state |> Map.update!(:waiting, &:queue.in(run_id, &1)) |> fill()}

  # The worker answered: its run is written down, whatever it found.
  @impl true
  def handle_info({ref, _result}, %{working: working} = state) when is_map_key(working, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> drop(ref) |> fill()}
  end

  # The worker died without answering: its run is closed as failed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{working: working} = state)
      when is_map_key(working, ref) do
    %{run_id: run_id} = working[ref]
    Logger.error("Assist #{run_id}: its worker died: #{inspect(reason)}")
    :ok = Assist.interrupt_run(run_id)
    {:noreply, state |> drop(ref) |> fill()}
  end

  # A worker still going at the deadline is stopped, which closes its run.
  def handle_info({:overdue, ref}, %{working: working} = state) when is_map_key(working, ref) do
    %{pid: pid, run_id: run_id} = working[ref]
    Logger.error("Assist #{run_id}: its worker ran past #{@deadline_ms} ms and was stopped")
    _ = Task.Supervisor.terminate_child(@task_supervisor, pid)
    {:noreply, state}
  end

  def handle_info(_late_or_unknown, state), do: {:noreply, state}

  defp fill(%{working: working, waiting: waiting} = state)
       when map_size(working) < @max_at_once do
    case :queue.out(waiting) do
      {{:value, run_id}, waiting} ->
        state |> Map.put(:waiting, waiting) |> begin(run_id) |> fill()

      {:empty, _waiting} ->
        state
    end
  end

  defp fill(state), do: state

  defp begin(state, run_id) do
    task = Task.Supervisor.async_nolink(@task_supervisor, Work, :run, [run_id])
    Process.send_after(self(), {:overdue, task.ref}, @deadline_ms)
    put_in(state, [:working, task.ref], %{run_id: run_id, pid: task.pid})
  end

  defp drop(state, ref), do: update_in(state, [:working], &Map.delete(&1, ref))
end
