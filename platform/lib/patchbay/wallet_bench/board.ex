defmodule Patchbay.WalletBench.Board do
  @moduledoc """
  The Agent Wallet Bench read once a minute and shared with every visitor of
  the board (`/wallet-bench`, `GET /api/wallet-bench`, the `read_wallet_bench`
  tool), of How the bench works, of each pair's page
  (`/wallet-bench/<agent>/<wallet>`, its JSON and the `read_wallet_bench_pair`
  tool) and of the sitemap, so a visit reads nothing from Techtree's views and
  holds no database connection. It runs on each machine that serves pages and
  keeps its reading in `Patchbay.SharedReading` (`key/1`):

  - `:board`, the board as a visit with no filters sees it, built once;
  - `:rows`, the rows it was built from but the checks and the runs' steps,
    and `{:checks, grid}`, each grid's checks, from which a visit with filters
    builds the grids it shows in memory (`Patchbay.WalletBench.Matrix.board/3`),
    copying only the checks of those grids;
  - `:method`, the checks How the bench works lists;
  - `:pages`, what every pair's page and the sitemap share: the agents and
    wallets, Techtree's notes, fixed outcomes and extra notes, every recorded
    version a filter may name, and each pair's newest run;
  - `{:pair, harness_id, wallet_id}`, one for each agent and wallet on the
    roster: the pair's runs with their steps, its sets and its checks, so a
    visit copies only the pair it shows.

  This is the second shape the `elixir-stack` skill lets keep a shared reading,
  a reread on notice. Techtree sends Patchbay no notice when a run finishes, so
  the only notice is the minute's heal: the site's Oban schedule runs
  `Patchbay.SharedReading.Heal` for `:wallet_bench` each minute, and this
  process reads the whole bench again when it hears it. It never schedules a
  read itself, holds nothing between passes, and never writes the database.

  A pass reads Techtree's seven views one after another in one transaction
  on one connection, with Postgres' own `statement_timeout` set
  for that transaction (`config :patchbay, #{inspect(__MODULE__)},
  statement_timeout:`, five seconds in production). Postgres cancels a view
  that runs longer, so a slow view holds the connection for at most that long,
  once a minute, whatever the number of visitors. After each pass the process
  hibernates, so the rows it read are not kept in its memory.

  The first pass happens as it starts, before the endpoint serves a page, so
  the first visit after a boot finds the bench already read. If that pass
  fails, the keys hold the degraded mark and no reading: the board answers
  503 with words saying to try again in a minute, until the next minute's
  pass reads it. A later pass that fails keeps the last board on show, marked
  degraded so the page says the latest read did not answer, and logs one
  warning line; it never stops this process or a page.
  """

  use GenServer

  require Logger

  alias Patchbay.Repo
  alias Patchbay.SharedReading
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.Sets

  @kind :wallet_bench
  @whole [:board, :method, :rows, :pages]

  @type part ::
          :board
          | :rows
          | :method
          | :pages
          | {:checks, String.t()}
          | {:pair, String.t(), String.t()}
  @type read :: %{at: DateTime.t(), degraded?: boolean()}

  @doc "Where one part of the shared bench is held."
  @spec key(part()) :: SharedReading.key()
  def key({:checks, grid}) when is_binary(grid), do: {@kind, "checks:" <> grid}

  def key({:pair, harness_id, wallet_id}) when is_binary(harness_id) and is_binary(wallet_id),
    do: {@kind, "pair:" <> harness_id <> "/" <> wallet_id}

  def key(part) when part in @whole, do: {@kind, Atom.to_string(part)}

  # The parts every pass shares, whoever is on the roster.
  defp fixed_parts, do: @whole ++ Enum.map(Matrix.grids(), &{:checks, &1})

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The board under `filters` with `grids` built, from the shared reading:
  `{:ok, board, read}`, where `read` says when the bench was read and whether
  the latest pass failed, `:unread` while no pass has read it since the site
  started, or `:busy` when as many filtered boards as may be built at once
  are being built.

  A visit with no filters is handed the board built once, with every grid,
  and never waits. One with filters builds `grids` from the shared rows in a
  process of `#{inspect(__MODULE__)}.Builds`, a `Task.Supervisor` that runs
  at most four at a time: each build takes tens of megabytes for a moment,
  so the cap bounds that memory however many visitors filter at once. The
  build's memory goes with its process; only the board comes back.
  """
  @spec board(map(), [String.t()]) :: {:ok, map(), read()} | :unread | :busy
  def board(filters, _grids) when filters == %{}, do: shared(:board)
  def board(filters, grids), do: in_build(fn -> filtered(filters, grids) end)

  defp filtered(filters, grids) do
    with {:ok, rows, read} <- shared(:rows),
         {:ok, checks} <- checks(grids) do
      {:ok, Matrix.board(Map.put(rows, :checks, checks), filters, grids), read}
    end
  end

  # Runs `build` in one of the supervisor's processes and waits for its
  # answer, or answers `:busy` at once when all of them are taken. A build
  # that crashes takes the visit with it, as it would have in the visit.
  defp in_build(build) do
    caller = self()
    answer = make_ref()

    case Task.Supervisor.start_child(__MODULE__.Builds, fn -> send(caller, {answer, build.()}) end) do
      {:ok, pid} ->
        watch = Process.monitor(pid)

        receive do
          {^answer, result} ->
            Process.demonitor(watch, [:flush])
            result

          {:DOWN, ^watch, :process, _pid, reason} ->
            exit(reason)
        end

      {:error, :max_children} ->
        :busy
    end
  end

  @doc "The supervisor filtered builds run under, four at a time."
  def builds, do: {Task.Supervisor, name: __MODULE__.Builds, max_children: 4}

  defp checks(grids) do
    Enum.reduce_while(grids, {:ok, []}, fn grid, {:ok, held} ->
      case shared({:checks, grid}) do
        {:ok, checks, _read} -> {:cont, {:ok, checks ++ held}}
        :unread -> {:halt, :unread}
      end
    end)
  end

  @doc "How the bench works from the shared reading, as `board/2` answers."
  @spec method() :: {:ok, map(), read()} | :unread
  def method, do: shared(:method)

  @doc """
  What every pair's page and the sitemap share, as `board/2` answers:
  `roster`, `notes`, `fixed` and `extra_notes` as Techtree's views hold them,
  `options`, every recorded version a filter may name
  (`Patchbay.WalletBench.Sets.options/1`), and `newest`, each
  `{harness_id, wallet_id}` that has run with when its newest run finished.
  """
  @spec pages() :: {:ok, map(), read()} | :unread
  def pages, do: shared(:pages)

  @doc """
  One agent and wallet pair from the shared reading, as `board/2` answers:
  its `results` with their steps, by test and then run; its `summaries`, one
  for each set; and its `checks`, by test, run and check. Only a pair on the
  roster (`pages/0`) is held.
  """
  @spec pair(String.t(), String.t()) :: {:ok, map(), read()} | :unread
  def pair(harness_id, wallet_id), do: shared({:pair, harness_id, wallet_id})

  defp shared(part) do
    case SharedReading.fetch(key(part)) do
      {:ok, %{reading: nil}} -> :unread
      {:ok, %{reading: reading} = entry} -> {:ok, reading, Map.take(entry, [:at, :degraded?])}
      :error -> :unread
    end
  end

  @doc """
  Reads the whole bench and shares it: the pass this process runs as it
  starts and on each minute's heal. A test calls it directly, in place of
  the process.
  """
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    with {:ok, rows} <- read(),
         {:ok, parts} <- built(rows),
         :ok <- put(parts) do
      forget_left(parts)
    else
      {:error, reason} = failed ->
        Logger.warning(
          "Wallet Bench: the minute's read of Techtree's views failed, so the board " <>
            "keeps its last reading: #{summary(reason)}"
        )

        Enum.each(held(), &SharedReading.degraded/1)
        failed
    end
  end

  # Every key this pass marks degraded: the fixed parts, so a site that has
  # never read the bench still counts them as unread, and each pair held.
  defp held,
    do:
      Enum.uniq(
        Enum.map(fixed_parts(), &key/1) ++ Enum.map(SharedReading.ids(@kind), &{@kind, &1})
      )

  # A pair that has left the roster is forgotten once the pages that named it
  # have been replaced, so no visit finds it named and not held.
  defp forget_left(parts) do
    shared = MapSet.new(parts, fn {part, _reading} -> key(part) end)

    for id <- SharedReading.ids(@kind), not MapSet.member?(shared, {@kind, id}) do
      SharedReading.delete({@kind, id})
    end

    :ok
  end

  # Each grid's checks and each pair first and the board last, so a visit
  # that reads in between finds checks and pairs at least as new as the rows
  # and pages it was sent from.
  defp put(parts) do
    Enum.reduce_while(parts, :ok, fn {part, reading}, :ok ->
      case SharedReading.put(key(part), reading) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp read do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('statement_timeout', $1, true)", [statement_timeout()])

      case Matrix.read_rows() do
        {:ok, rows} -> rows
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    # The database not answering raises beneath Ash. It is a read not taken,
    # never a reason for this process, and the site with it, to stop.
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp statement_timeout,
    do:
      Application.fetch_env!(:patchbay, __MODULE__)
      |> Keyword.fetch!(:statement_timeout)
      |> to_string()

  # Rows that do not fit together, such as a run whose set Techtree has not
  # summed up, are a read not taken like any other: the last board stays.
  defp built(rows) do
    by_grid = Enum.group_by(rows.checks, & &1.grid)
    # The board and How the bench works show no steps, so they are built and
    # shared without them.
    board_rows =
      Map.update!(rows, :results, fn runs -> Enum.map(runs, &Map.delete(&1, :turns)) end)

    {:ok,
     Enum.map(Matrix.grids(), &{{:checks, &1}, Map.get(by_grid, &1, [])}) ++
       pairs(rows) ++
       [
         rows: Map.delete(board_rows, :checks),
         pages: pages(rows),
         method: Matrix.method(board_rows),
         board: Matrix.board(board_rows)
       ]}
  rescue
    error -> {:error, error}
  end

  defp pages(rows) do
    %{
      roster: rows.roster,
      notes: rows.notes,
      fixed: rows.fixed,
      extra_notes: rows.extra_notes,
      options: Sets.options(rows.results),
      newest:
        rows.results
        |> Enum.group_by(&{&1.harness_id, &1.wallet_id}, & &1.finished_at)
        |> Map.new(fn {pair, finished} -> {pair, Enum.max(finished, DateTime)} end)
    }
  end

  defp pairs(rows) do
    results = Enum.group_by(rows.results, &{&1.harness_id, &1.wallet_id})
    summaries = Enum.group_by(rows.summaries, &{&1.harness_id, &1.wallet_id})
    checks = Enum.group_by(rows.checks, &{&1.harness_id, &1.wallet_id})

    for %{kind: "harness", id: harness_id} <- rows.roster,
        %{kind: "wallet", id: wallet_id} <- rows.roster do
      pair = {harness_id, wallet_id}

      {{:pair, harness_id, wallet_id},
       %{
         results: results |> Map.get(pair, []) |> Enum.sort_by(&{&1.grid, &1.run}),
         summaries: Map.get(summaries, pair, []),
         checks: checks |> Map.get(pair, []) |> Enum.sort_by(&{&1.grid, &1.run, &1.criterion_id})
       }}
    end
  end

  # One line in the log, whatever shape the reason has: of an error Ash wraps,
  # the error beneath it, without the trail of where it was passed along.
  defp summary(%{errors: [first | _]}), do: summary(first)

  defp summary(%{__exception__: true} = error) do
    lines =
      error
      |> Exception.message()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 =~ ~r/^(Bread Crumbs:|>)/))

    case Enum.find(lines, &String.contains?(&1, "** (")) do
      nil ->
        line(Enum.join(lines, " "))

      beneath ->
        beneath |> String.split("** (", parts: 2) |> List.last() |> then(&line("** (" <> &1))
    end
  end

  defp summary(reason), do: reason |> inspect(limit: 5) |> line()

  defp line(words), do: words |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(@kind)
    refresh()
    {:ok, nil, :hibernate}
  end

  @impl true
  def handle_info({:shared_reading_heal, @kind}, state) do
    refresh()
    {:noreply, state, :hibernate}
  end
end
