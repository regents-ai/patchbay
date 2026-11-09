defmodule Patchbay.WalletBench do
  @moduledoc """
  Agent Wallet Bench results, read from Techtree.

  Techtree runs the bench and publishes what it found as read-only views in
  its own schema of the shared database. Patchbay reads them in full once a
  minute and shares that reading with every visitor of the board and of How
  the bench works and of each pair's page (`Patchbay.WalletBench.Board`).
  Patchbay keeps no names, rules or wording of its
  own: every agent and wallet name, outcome meaning and note comes from the
  views.

  `board_page/2` and `pair_page/1` take a visit's query as it arrived, check
  it once against the bench as last read, and answer what the page, its JSON
  and its tool show, or `:not_found` for a query that names nothing on the
  bench.
  """

  use Ash.Domain, otp_app: :patchbay

  alias Patchbay.WalletBench.Board
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.RunRecords
  alias Patchbay.WalletBench.Sets

  resources do
    resource Patchbay.WalletBench.Result do
      define(:list_results, action: :read)
    end

    resource Patchbay.WalletBench.SetSummary do
      define(:list_sets, action: :read)
    end

    resource Patchbay.WalletBench.Check do
      define(:list_checks, action: :read)
    end

    resource Patchbay.WalletBench.Fixed do
      define(:list_fixed, action: :read)
    end

    resource Patchbay.WalletBench.RosterEntry do
      define(:list_roster, action: :read)
    end

    resource Patchbay.WalletBench.Note do
      define(:list_notes, action: :read)
    end

    resource Patchbay.WalletBench.ExtraNote do
      define(:list_extra_notes, action: :read)
    end
  end

  @type unavailable :: :unread | :busy | :not_found

  @doc """
  One test's board (`?test=`, the first test when none is named), as the page
  and `GET /api/wallet-bench` show it: `matrix`, the `test` shown and when the
  bench was `read`. A filter left at "Any recorded version" is no filter.
  With filters, only the test shown is built, or every test when
  `every_grid?`, as the Markdown page lists them all. `:unread` and `:busy`
  are `Patchbay.WalletBench.Board.board/2`'s.
  """
  @spec board_page(map(), boolean()) :: {:ok, keyword()} | unavailable()
  def board_page(params, every_grid?) do
    with {:ok, context} <- context(params),
         test = context["test"],
         filters =
           context |> Map.take(Sets.filters()) |> Map.reject(fn {_key, id} -> id == "" end),
         grids = if(every_grid?, do: Matrix.grids(), else: [test]),
         {:ok, matrix, read} <- Board.board(filters, grids),
         true <- Sets.valid_filters?(filters, matrix.options) || :not_found do
      {:ok, [matrix: matrix, test: Enum.find(matrix.grids, &(&1.grid == test)), read: read]}
    end
  end

  @doc """
  One agent and wallet pair's runs (`harness_id`, `wallet_id`), as the page
  and its JSON show them, narrowed by the query's test, filters, chosen set,
  sets compared, run and check. The run shown is the newest of its test
  unless the query names one, and its whole public record is read from
  Techtree (`report`, or `report_error` when that read failed).
  """
  @spec pair_page(map()) :: {:ok, keyword()} | :unread | :not_found
  def pair_page(%{"harness_id" => harness_id, "wallet_id" => wallet_id} = params) do
    with {:ok, context} <- context(params),
         {:ok, pages, _read} <- Board.pages(),
         {:ok, harness, wallet} <- on_roster(pages.roster, harness_id, wallet_id),
         {:ok, held, _read} <- Board.pair(harness.id, wallet.id) do
      pair_page(pages, held, harness, wallet, context, params)
    end
  end

  defp pair_page(pages, held, harness, wallet, context, params) do
    test = context["test"]
    filters = Map.take(context, Sets.filters())
    results = Sets.filter(held.results, filters)
    sets = Sets.build(results, held.summaries)
    selection = Map.take(params, ~w(set baseline compare))
    shown = Enum.find(sets, &(&1.id == selection["set"]))
    check = params["check"]

    # A pair with no runs may still carry a filter option recorded by
    # another pair: `options` holds every pair's.
    with true <- Sets.valid_filters?(filters, pages.options) || :not_found,
         true <-
           Enum.all?(selection, fn {_key, id} -> id == "" or Enum.any?(sets, &(&1.id == id)) end) ||
             :not_found,
         true <- (is_nil(shown) or shown.grid == test) || :not_found,
         in_set = in_set(results, shown),
         {:ok, selected_run} <- selected_run(in_set, test, params["run"]),
         true <- (is_nil(check) or check in checks(test)) || :not_found do
      {report, report_error} = report(selected_run)

      notes =
        Enum.filter(
          pages.extra_notes,
          &({&1.kind, &1.id} in [{"harness", harness.id}, {"wallet", wallet.id}])
        )

      {:ok,
       [
         harness: harness,
         wallet: wallet,
         notes: Matrix.notes(pages.notes),
         grids:
           grids(
             in_set,
             held.checks,
             pages.fixed,
             Matrix.stopped_at(results),
             notes,
             harness,
             wallet
           ),
         sets: sets,
         shown: shown,
         selection: selection,
         comparison: Sets.compare(sets, selection["baseline"], selection["compare"], held.checks),
         extra_notes: Enum.filter(notes, &noted?(&1, in_set)),
         test: test,
         context: context,
         filters: filters,
         selected_run: selected_run,
         report: report,
         report_error: report_error,
         selected_check: check,
         focus: focus(check, selected_run)
       ]}
    end
  end

  # The query's test, the first when none is named, and its filters, each
  # one text.
  defp context(params) do
    test = Map.get(params, "test", hd(Matrix.grids()))
    filters = Map.take(params, Sets.filters())

    if test in Matrix.grids() and Enum.all?(filters, fn {_key, value} -> is_binary(value) end),
      do: {:ok, Map.put(filters, "test", test)},
      else: :not_found
  end

  defp on_roster(roster, harness_id, wallet_id) do
    harness = Enum.find(roster, &(&1.kind == "harness" and &1.id == harness_id))
    wallet = Enum.find(roster, &(&1.kind == "wallet" and &1.id == wallet_id))
    if harness && wallet, do: {:ok, harness, wallet}, else: :not_found
  end

  # A chosen set narrows its own test to its runs; the other tests keep all of theirs.
  defp in_set(results, nil), do: results

  defp in_set(results, set),
    do: Enum.filter(results, &(&1.grid != set.grid or &1.set_id == set.id))

  defp selected_run(results, test, nil) do
    {:ok,
     results
     |> Enum.filter(&(&1.grid == test))
     |> Enum.max_by(&{DateTime.to_unix(&1.finished_at, :microsecond), &1.attempt_id}, fn ->
       nil
     end)}
  end

  defp selected_run(results, test, id) when is_binary(id) do
    case Enum.find(results, &(&1.grid == test and &1.attempt_id == id)) do
      nil -> :not_found
      run -> {:ok, run}
    end
  end

  defp selected_run(_results, _test, _id), do: :not_found

  # Install and make a wallet are judged on nine checks, each money test on five.
  defp checks(test) when test in ["install", "wallet"], do: Enum.map(1..9, &"C#{&1}")
  defp checks(_test), do: Enum.map(1..5, &"C#{&1}")

  defp report(nil), do: {nil, false}

  defp report(run) do
    case RunRecords.read(run) do
      {:ok, report} -> {report, false}
      {:error, _reason} -> {nil, true}
    end
  end

  defp focus(check, %{decided_by: decided_by}) when is_binary(check) and is_binary(decided_by),
    do: "wb-check-#{decided_by}-#{check}"

  defp focus(_check, _run), do: "recorded-run"

  # Each run carries its checks and whether Techtree noted anything about a
  # release it records.
  defp grids(results, checks, fixed, stopped, notes, harness, wallet) do
    checks = Enum.group_by(checks, &{&1.grid, &1.attempt_id})

    Enum.map(Matrix.grids(), fn grid ->
      %{
        grid: grid,
        stopped: if(grid == "wallet", do: stopped),
        fixed: Matrix.fixed_for(fixed, grid, harness.id, wallet.id),
        runs:
          for run <- results, run.grid == grid do
            %{
              result: run,
              checks: Map.get(checks, {grid, run.attempt_id}, []),
              noted?: Enum.any?(notes, &noted?(&1, [run]))
            }
          end
      }
    end)
  end

  # Whether any of these runs records the release: its agent or wallet at
  # the version the run's set records for it.
  defp noted?(%{kind: "harness", id: id, version: version}, runs),
    do: Enum.any?(runs, &(&1.harness_id == id and &1.set_versions["harness"] == version))

  defp noted?(%{kind: "wallet", id: id, version: version}, runs),
    do: Enum.any?(runs, &(&1.wallet_id == id and &1.set_versions["wallet"] == version))

  defp noted?(_release, _runs), do: false
end
