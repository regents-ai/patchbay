defmodule PatchbayWeb.WalletBenchController do
  @moduledoc """
  The Agent Wallet Bench board, `/wallet-bench`, one test at a time
  (`?test=wallet`; the first test when none is named), and one pair's runs,
  `/wallet-bench/<agent>/<wallet>`. Both read Techtree's published results
  when they are opened, so a finished run shows on the next visit.
  """

  use PatchbayWeb, :controller

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.Cohorts
  alias Patchbay.WalletBench.Matrix
  alias PatchbayWeb.Forum.NotFoundError

  def index(conn, params) do
    test = Map.get(params, "test", hd(Matrix.grids()))
    unless test in Matrix.grids(), do: raise(NotFoundError)
    filters = Map.take(params, Cohorts.filters())
    {:ok, matrix} = Matrix.read(filters)

    Enum.each(filters, fn {key, id} ->
      unless id == "" or Enum.any?(matrix.options[key], &(&1.id == id)),
        do: raise(NotFoundError)
    end)

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
    {:ok, checks} = WalletBench.pair_checks(harness_id, wallet_id)
    cohorts = Cohorts.groups(results)
    selection = Map.take(params, ~w(cohort baseline compare))

    Enum.each(selection, fn {_key, id} ->
      unless id == "" or Enum.any?(cohorts, &(&1.id == id)), do: raise(NotFoundError)
    end)

    comparison = Cohorts.compare(cohorts, selection["baseline"], selection["compare"], checks)

    stopped = Matrix.stopped_at(results)
    results = in_cohort(results, cohorts, selection["cohort"])

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
      cohorts: cohorts,
      selection: selection,
      comparison: comparison,
      test: test,
      context: context,
      filters: Map.take(context, Cohorts.filters())
    )
  end

  defp pair!(harness_id, wallet_id) do
    {:ok, roster} = WalletBench.list_roster()
    harness = Enum.find(roster, &(&1.kind == "harness" and &1.id == harness_id))
    wallet = Enum.find(roster, &(&1.kind == "wallet" and &1.id == wallet_id))
    unless harness && wallet, do: raise(NotFoundError)
    {harness, wallet}
  end

  defp in_cohort(results, _cohorts, cohort) when cohort in [nil, ""], do: results

  defp in_cohort(results, cohorts, cohort) do
    runs = cohorts |> Enum.find(%{runs: []}, &(&1.id == cohort)) |> Map.fetch!(:runs)
    Enum.filter(results, &(&1 in runs))
  end

  defp bench_context(params) do
    test = Map.get(params, "test", hd(Matrix.grids()))
    unless test in Matrix.grids(), do: raise(NotFoundError)
    Map.take(params, ["test" | Cohorts.filters()]) |> Map.put("test", test)
  end
end
