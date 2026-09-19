defmodule Patchbay.Forum.JevReader do
  @moduledoc """
  Has Jev read each paid priority report once.

  A GenServer wakes on an interval and works the report table itself — a
  report awaits its reading until the reading's row exists, so a restart loses
  nothing and a report is never read twice. A call that fails is tried again
  on a later pass, up to a few times per report while this process lives;
  after that the report is left alone until the next boot, so a report Jev
  cannot answer is not asked about forever.

  Nothing waits on this: a thread without a reading simply has no Jev line.
  """

  use GenServer

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Forum.Jev

  @interval_ms 30_000
  @max_attempts 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :read, @interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:read, attempts) do
    attempts = read_reports(attempts)
    Process.send_after(self(), :read, @interval_ms)
    {:noreply, attempts}
  end

  @doc """
  Reads every report still awaiting Jev, and returns the failed-attempt counts
  to carry into the next pass. Called by the worker's timer; also callable
  directly so an operator console can run one pass.
  """
  @spec read_reports(%{optional(Ash.UUID.t()) => pos_integer()}) :: %{
          optional(Ash.UUID.t()) => pos_integer()
        }
  def read_reports(attempts \\ %{}) do
    given_up = for {id, @max_attempts} <- attempts, do: id

    # Internal read and write: the worker answers to nobody's request.
    Forum.list_reports_awaiting_jev!(given_up, load: [:site, :tool], authorize?: false)
    |> Enum.reduce(attempts, fn report, attempts ->
      with {:ok, answers} <- Jev.read(report),
           {:ok, _reading} <-
             Forum.record_jev_reading(Map.put(answers, :report_id, report.id),
               authorize?: false
             ) do
        Map.delete(attempts, report.id)
      else
        {:error, reason} ->
          Logger.warning("Jev reading failed for report #{report.id}: #{inspect(reason)}")
          Map.update(attempts, report.id, 1, &(&1 + 1))
      end
    end)
  end

  defp enabled? do
    Application.get_env(:patchbay, :jev_reader, true) and Jev.configured?()
  end
end
