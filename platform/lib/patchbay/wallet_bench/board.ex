defmodule Patchbay.WalletBench.Board do
  @moduledoc """
  The Agent Wallet Bench read once a minute and shared with every visitor of
  the board (`/wallet-bench`, `GET /api/wallet-bench`, the `read_wallet_bench`
  tool) and of How the bench works, so a visit reads nothing from Techtree's
  views and holds no database connection. It runs on each machine that
  serves pages and keeps its reading in `Patchbay.SharedReading` (`key/1`):

  - `:board`, the board as a visit with no filters sees it, built once;
  - `:rows`, the rows it was built from but the checks, and `{:checks, grid}`,
    each grid's checks, from which a visit with filters builds the grids it
    shows in memory (`Patchbay.WalletBench.Matrix.board/3`), copying only
    the checks of those grids;
  - `:method`, the checks How the bench works lists.

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

  @kind :wallet_bench
  @whole [:board, :method, :rows]

  @type part :: :board | :rows | :method | {:checks, String.t()}
  @type read :: %{at: DateTime.t(), degraded?: boolean()}

  @doc "Where one part of the shared bench is held."
  @spec key(part()) :: SharedReading.key()
  def key({:checks, grid}) when is_binary(grid), do: {@kind, "checks:" <> grid}
  def key(part) when part in @whole, do: {@kind, Atom.to_string(part)}

  @doc "Every part of the shared bench: one for each test's checks."
  @spec parts() :: [part()]
  def parts, do: @whole ++ Enum.map(Matrix.grids(), &{:checks, &1})

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The board under `filters` with `grids` built, from the shared reading:
  `{:ok, board, read}`, where `read` says when the bench was read and whether
  the latest pass failed, or `:unread` while no pass has read it since the
  site started. A visit with no filters is handed the board built once, with
  every grid; one with filters builds `grids` from the shared rows.
  """
  @spec board(map(), [String.t()]) :: {:ok, map(), read()} | :unread
  def board(filters, _grids) when filters == %{}, do: shared(:board)

  def board(filters, grids) do
    with {:ok, rows, read} <- shared(:rows),
         {:ok, checks} <- checks(grids) do
      {:ok, Matrix.board(Map.put(rows, :checks, checks), filters, grids), read}
    end
  end

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
      :ok
    else
      {:error, reason} = failed ->
        Logger.warning(
          "Wallet Bench: the minute's read of Techtree's views failed, so the board " <>
            "keeps its last reading: #{summary(reason)}"
        )

        Enum.each(parts(), &SharedReading.degraded(key(&1)))
        failed
    end
  end

  # Each grid's checks first and the board last, so a visit that reads in
  # between finds checks at least as new as its rows.
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

    {:ok,
     Enum.map(Matrix.grids(), &{{:checks, &1}, Map.get(by_grid, &1, [])}) ++
       [
         rows: Map.delete(rows, :checks),
         method: Matrix.method(rows),
         board: Matrix.board(rows)
       ]}
  rescue
    error -> {:error, error}
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
