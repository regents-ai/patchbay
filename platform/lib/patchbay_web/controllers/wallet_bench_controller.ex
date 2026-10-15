defmodule PatchbayWeb.WalletBenchController do
  @moduledoc """
  The Agent Wallet Bench board, `/wallet-bench`, one test at a time
  (`?test=wallet`; the first test when none is named), and one pair's runs,
  `/wallet-bench/<agent>/<wallet>`. Both read Techtree's published results
  when they are opened, so a finished run shows on the next visit.
  """

  use PatchbayWeb, :controller

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.ExtraNotes
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.Sets
  alias PatchbayWeb.Forum.NotFoundError

  def index(conn, params) do
    context = bench_context(params)
    test = context["test"]
    filters = Map.take(context, Sets.filters())
    {:ok, matrix} = Matrix.read(filters)

    unless Sets.valid_filters?(filters, matrix.options), do: raise(NotFoundError)

    render(conn, :index,
      page_title: "Agent Wallet Bench",
      matrix: matrix,
      test: Enum.find(matrix.grids, &(&1.grid == test))
    )
  end

  def show(conn, %{"harness_id" => harness_id, "wallet_id" => wallet_id} = params) do
    context = bench_context(params)
    test = context["test"]
    {harness, wallet} = pair!(harness_id, wallet_id)

    {:ok, notes} = WalletBench.list_notes()
    {:ok, fixed} = WalletBench.list_fixed()
    {:ok, results} = WalletBench.pair_results(harness_id, wallet_id)

    filters = Map.take(context, Sets.filters())
    validate_pair_filters!(filters)

    {:ok, summaries} = WalletBench.pair_sets(harness_id, wallet_id)
    {:ok, checks} = WalletBench.pair_checks(harness_id, wallet_id)
    {:ok, extra_notes} = WalletBench.list_extra_notes()
    sets = Sets.build(results, summaries)
    selection = Map.take(params, ~w(set baseline compare))

    Enum.each(selection, fn {_key, id} ->
      unless id == "" or Enum.any?(sets, &(&1.id == id)), do: raise(NotFoundError)
    end)

    comparison = Sets.compare(sets, selection["baseline"], selection["compare"], checks)

    stopped = Matrix.stopped_at(results)
    shown = Enum.find(sets, &(&1.id == selection["set"]))

    if get_format(conn) == "json" && shown && shown.grid != test, do: raise(NotFoundError)

    results = in_set(results, shown)

    checks = Enum.group_by(checks, &{&1.grid, &1.attempt_id})

    grids =
      Enum.map(Matrix.grids(), fn grid ->
        %{
          grid: grid,
          stopped: if(grid == "wallet", do: stopped),
          fixed: Matrix.fixed_for(fixed, grid, harness_id, wallet_id),
          runs:
            for run <- results, run.grid == grid do
              %{result: run, checks: Map.get(checks, {grid, run.attempt_id}, [])}
            end
        }
      end)

    render(conn, :show,
      page_title: "#{harness.name} with #{wallet.name}",
      harness: harness,
      wallet: wallet,
      notes: Matrix.notes(notes),
      grids: grids,
      sets: sets,
      shown: shown,
      selection: selection,
      comparison: comparison,
      extra_notes:
        extra_notes |> ExtraNotes.by_release([harness, wallet]) |> ExtraNotes.for_runs(results),
      test: test,
      context: context,
      filters: filters
    )
  end

  # A pair with no runs may still carry a matrix option recorded by another pair.
  defp validate_pair_filters!(filters) do
    if Enum.any?(filters, fn {_key, selected} -> selected != "" end) do
      {:ok, recorded} = WalletBench.list_results(query: [select: [:set_versions]])
      unless Sets.valid_filters?(filters, Sets.options(recorded)), do: raise(NotFoundError)
    end
  end

  defp pair!(harness_id, wallet_id) do
    {:ok, roster} = WalletBench.list_roster()
    harness = Enum.find(roster, &(&1.kind == "harness" and &1.id == harness_id))
    wallet = Enum.find(roster, &(&1.kind == "wallet" and &1.id == wallet_id))
    unless harness && wallet, do: raise(NotFoundError)
    {harness, wallet}
  end

  # A chosen set narrows its own test to its runs; the other tests keep all of theirs.
  defp in_set(results, nil), do: results

  defp in_set(results, set),
    do: Enum.filter(results, &(&1.grid != set.grid or &1.set_id == set.id))

  defp bench_context(params) do
    test = Map.get(params, "test", hd(Matrix.grids()))
    unless test in Matrix.grids(), do: raise(NotFoundError)

    unless Enum.all?(Map.take(params, Sets.filters()), fn {_key, value} -> is_binary(value) end),
      do: raise(NotFoundError)

    Map.take(params, ["test" | Sets.filters()]) |> Map.put("test", test)
  end
end
