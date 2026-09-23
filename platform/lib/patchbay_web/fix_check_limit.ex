defmodule PatchbayWeb.FixCheckLimit do
  @moduledoc """
  Counts, for each connection, the different addresses the free fix was
  pointed at where Patchbay found no WebMCP tools in the last hour. The one
  that makes it more than three starts a wait of a full hour from that
  moment, during which the connection is not checked for. Every check a
  connection asks for is also counted, so the check is never a way to have
  Patchbay fetch pages in bulk.

  It lives in this node's memory, which is the whole of Patchbay: the site
  runs on one machine. Rows carry the moment they lapse and are swept once
  a minute; a lapsed row is never read as a live one.
  """

  use GenServer

  @table __MODULE__
  @misses_allowed 3
  @hour :timer.hours(1)
  @checks_allowed 30
  @check_window :timer.minutes(10)
  @sweep_every :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Draws one check for the connection; `{:wait, seconds}` when it may not check now."
  @spec draw(String.t(), integer()) :: :ok | {:wait, pos_integer()}
  def draw(visitor, now \\ now()) do
    case :ets.lookup(@table, {:waiting, visitor}) do
      [{_key, until}] when until > now -> {:wait, seconds(until - now)}
      _not_waiting -> checked(visitor, now)
    end
  end

  @doc """
  Counts an address without tools against the connection, once in any hour
  however often it is asked about: how many the connection has had in the
  last hour, or `{:wait, seconds}` when that is more than three.
  """
  @spec missed(String.t(), String.t(), integer()) ::
          {:ok, non_neg_integer()} | {:wait, pos_integer()}
  def missed(visitor, site_url, now \\ now()) do
    key = {:missed, visitor, site_url}

    case :ets.lookup(@table, key) do
      [{^key, lapses}] when lapses > now -> :counted_already
      _new -> :ets.insert(@table, {key, now + @hour})
    end

    case misses(visitor, now) do
      misses when misses > @misses_allowed ->
        :ets.insert(@table, {{:waiting, visitor}, now + @hour})
        {:wait, seconds(@hour)}

      misses ->
        {:ok, misses}
    end
  end

  @doc "How many addresses without tools the connection has had in the last hour."
  @spec misses(String.t(), integer()) :: non_neg_integer()
  def misses(visitor, now \\ now()) do
    :ets.select_count(@table, [{{{:missed, visitor, :_}, :"$1"}, [{:>, :"$1", now}], [true]}])
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now()

    :ets.select_delete(@table, [
      {{:_, :"$1"}, [{:"=<", :"$1", now}], [true]},
      {{:_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  # Checks are counted in ten-minute windows of the clock.
  defp checked(visitor, now) do
    window = div(now, @check_window)
    lapses = (window + 1) * @check_window
    key = {:checks, visitor, window}

    if :ets.update_counter(@table, key, {3, 1}, {key, lapses, 0}) > @checks_allowed,
      do: {:wait, seconds(lapses - now)},
      else: :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now, do: System.system_time(:millisecond)

  defp seconds(milliseconds), do: milliseconds |> div(1000) |> max(1)
end
