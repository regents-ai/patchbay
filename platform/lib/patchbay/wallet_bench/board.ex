defmodule Patchbay.WalletBench.Board do
  @moduledoc """
  The Agent Wallet Bench read once a minute and shared with every visitor of
  the board (`/wallet-bench`, `GET /api/wallet-bench`, the `read_wallet_bench`
  tool) and of How the bench works, so a visit reads nothing from Techtree's
  views and holds no database connection. It runs on each machine that
  serves pages and keeps its reading in `Patchbay.SharedReading` under three
  keys (`key/1`):

  - `:board`, the board as a visit with no filters sees it, built once;
  - `:rows`, every row it was built from, from which a visit with filters
    builds its own board in memory (`Patchbay.WalletBench.Matrix.board/2`);
  - `:method`, the checks How the bench works lists.

  This is the second shape the `elixir-stack` skill lets keep a shared reading,
  a reread on notice. Techtree sends Patchbay no notice when a run finishes, so
  the only notice is the minute's heal: the site's Oban schedule runs
  `Patchbay.SharedReading.Heal` for `:wallet_bench` each minute, and this
  process reads the whole bench again when it hears it. It never schedules a
  read itself, holds nothing between passes, and never writes the database.
  A pass reads Techtree's seven views one after another on one connection at
  a time, each bounded by `@timeout`, so a slow view can hold a connection for
  at most that long, once a minute, whatever the number of visitors.

  The first pass happens as it starts, before the endpoint serves a page, so
  the first visit after a boot finds the bench already read. If that pass
  fails, the keys hold the degraded mark and no reading: the board answers
  503 with words saying to try again in a minute, until the next minute's
  pass reads it. A later pass that fails keeps the last board on show, marked
  degraded so the page says the latest read did not answer, and logs one
  warning; it never stops this process or a page.
  """

  use GenServer

  require Logger

  alias Patchbay.SharedReading
  alias Patchbay.WalletBench.Matrix

  @kind :wallet_bench
  @parts [:rows, :method, :board]

  # How long one view's read may take before the pass gives up on it. The
  # costly two take about 150 ms each on production's bench.
  @timeout 5_000

  @type part :: :board | :rows | :method

  @doc "Where one part of the shared bench is held."
  @spec key(part()) :: SharedReading.key()
  def key(part) when part in @parts, do: {@kind, Atom.to_string(part)}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The board under `filters`, from the shared reading: `{:ok, board, read}`,
  where `read` says when the bench was read and whether the latest pass
  failed, or `:unread` while no pass has read it since the site started.
  A visit with no filters is handed the board built once; one with filters
  builds its own from the shared rows.
  """
  @spec board(map()) :: {:ok, map(), %{at: DateTime.t(), degraded?: boolean()}} | :unread
  def board(filters) when filters == %{}, do: shared(:board, & &1)
  def board(filters), do: shared(:rows, &Matrix.board(&1, filters))

  @doc "How the bench works from the shared reading, as `board/1` answers."
  @spec method() :: {:ok, map(), %{at: DateTime.t(), degraded?: boolean()}} | :unread
  def method, do: shared(:method, & &1)

  defp shared(part, build) do
    case SharedReading.fetch(key(part)) do
      {:ok, %{reading: nil}} ->
        :unread

      {:ok, %{reading: reading} = entry} ->
        {:ok, build.(reading), Map.take(entry, [:at, :degraded?])}

      :error ->
        :unread
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
         {:ok, method, board} <- built(rows),
         :ok <- SharedReading.put(key(:rows), rows),
         :ok <- SharedReading.put(key(:method), method),
         :ok <- SharedReading.put(key(:board), board) do
      :ok
    else
      {:error, reason} = failed ->
        Logger.warning(
          "Wallet Bench: the minute's read of Techtree's views failed, so the board " <>
            "keeps its last reading: #{summary(reason)}"
        )

        Enum.each(@parts, &SharedReading.degraded(key(&1)))
        failed
    end
  end

  defp read do
    Matrix.read_rows(timeout: @timeout)
  rescue
    # The database not answering raises beneath Ash. It is a read not taken,
    # never a reason for this process, and the site with it, to stop.
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  # Rows that do not fit together, such as a run whose set Techtree has not
  # summed up, are a read not taken like any other: the last board stays.
  defp built(rows) do
    {:ok, Matrix.method(rows), Matrix.board(rows)}
  rescue
    error -> {:error, error}
  end

  # One line in the log, whatever shape the reason has: of an error Ash
  # wraps, the line naming the error beneath it.
  defp summary(%{__exception__: true} = error) do
    message = Exception.message(error)

    case String.split(message, "** (", parts: 2) do
      [_wrapping, beneath] -> line("** (" <> hd(String.split(beneath, "\n", parts: 2)))
      [_whole] -> line(message)
    end
  end

  defp summary(reason), do: reason |> inspect(limit: 5) |> line()

  defp line(words), do: words |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

  @impl true
  def init(nil) do
    SharedReading.subscribe_heal(@kind)
    refresh()
    {:ok, nil}
  end

  @impl true
  def handle_info({:shared_reading_heal, @kind}, state) do
    refresh()
    {:noreply, state}
  end
end
