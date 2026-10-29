defmodule PatchbayWeb.WalletBenchController do
  @moduledoc """
  The Agent Wallet Bench board, `/wallet-bench`, one test at a time
  (`?test=wallet`; the first test when none is named), how the bench works,
  `/wallet-bench/how-it-works`, and one pair's runs,
  `/wallet-bench/<agent>/<wallet>`. The board and How the bench works show
  the bench as it was read within the last minute, shared with every visitor
  (`Patchbay.WalletBench.Board`), so a finished run shows within a minute and
  a visit reads nothing from Techtree. Until the bench has been read once
  since the site started, both answer 503 and say to try again in a minute;
  while four filtered boards are being built, a fifth answers 503 busy.
  A pair's page reads that pair's runs when it is opened.
  """

  use PatchbayWeb, :controller

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.Board
  alias Patchbay.WalletBench.ExtraNotes
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.PublicRun
  alias Patchbay.WalletBench.Sets
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.WalletBenchHTML
  alias PatchbayWeb.WalletBenchJSON

  def index(conn, params) do
    case board(params, every_grid?: get_format(conn) == "md") do
      {:ok, assigns} ->
        conn
        |> merge_assigns(PatchbayWeb.PublicDocuments.page("/wallet-bench"))
        |> render(:index, assigns ++ [page_data: [WalletBenchHTML.dataset(assigns[:matrix])]])

      why when why in [:unread, :busy] ->
        unavailable(conn, why)
    end
  end

  # One test's board, as the page and `GET /api/wallet-bench` show it, from
  # the bench as last read. A filter left at "Any recorded version" is no
  # filter. With filters, only the test shown is built, or every test for the
  # Markdown page, which lists them all.
  defp board(params, every_grid?: every_grid?) do
    context = bench_context(params)
    test = context["test"]
    filters = context |> Map.take(Sets.filters()) |> Map.reject(fn {_key, id} -> id == "" end)
    grids = if every_grid?, do: Matrix.grids(), else: [test]

    with {:ok, matrix, read} <- Board.board(filters, grids) do
      unless Sets.valid_filters?(filters, matrix.options), do: raise(NotFoundError)
      {:ok, [matrix: matrix, test: Enum.find(matrix.grids, &(&1.grid == test)), read: read]}
    end
  end

  # The bench has not been read since the site started, or as many filtered
  # boards as may be built at once are being built: a 503 in the format asked
  # for, with no crash to log on every visit.
  defp unavailable(conn, why) do
    %{error: %{message: message, hint: hint}} = body = refusal(why)

    conn =
      conn
      |> put_status(:service_unavailable)
      |> put_resp_header("retry-after", retry_after(why))

    case get_format(conn) do
      "json" ->
        json(conn, body)

      _page ->
        conn
        |> merge_assigns(PatchbayWeb.PublicDocuments.page("/wallet-bench"))
        |> render(:unavailable, heading: heading(why), words: message <> " " <> hint)
    end
  end

  defp refusal(:unread),
    do:
      PatchbayWeb.ApiError.body(
        "not_ready",
        "Wallet Bench results are still being read.",
        "Try again in a minute."
      )

  defp refusal(:busy),
    do: PatchbayWeb.ApiError.body("busy", "Wallet Bench is busy.", "Try again in a few seconds.")

  defp retry_after(:unread), do: "60"
  defp retry_after(:busy), do: "5"

  defp heading(:unread), do: "Not ready"
  defp heading(:busy), do: "Busy"

  @doc """
  The board for one test, as a status and the body `GET /api/wallet-bench`
  answers with for the same query: the `read_wallet_bench` tool.
  """
  @spec read_wallet_bench(map()) :: {atom(), map()}
  def read_wallet_bench(params) do
    read(fn ->
      case board(params, every_grid?: false) do
        {:ok, assigns} -> {:ok, WalletBenchJSON.index(Map.new(assigns))}
        why when why in [:unread, :busy] -> {:service_unavailable, refusal(why)}
      end
    end)
  end

  @doc """
  One pair's runs, as a status and the body
  `GET /api/wallet-bench/{harness_id}/{wallet_id}` answers with for the same
  query: the `read_wallet_bench_pair` tool.
  """
  @spec read_wallet_bench_pair(map()) :: {atom(), map()}
  def read_wallet_bench_pair(params),
    do: read(fn -> {:ok, WalletBenchJSON.show(Map.new(pair(params)))} end)

  # A bench address that names nothing raises NotFoundError, which the HTTP
  # door answers with the site's 404 body; a tool answers with the same.
  defp read(answer) do
    answer.()
  rescue
    NotFoundError -> {:not_found, PatchbayWeb.ErrorJSON.render("404.json", %{})}
  end

  def method(conn, _params) do
    case Board.method() do
      {:ok, key, _read} ->
        render(
          conn,
          :method,
          [key: key] ++ PatchbayWeb.PublicDocuments.page("/wallet-bench/how-it-works")
        )

      :unread ->
        unavailable(conn, :unread)
    end
  end

  def show(conn, params), do: render(conn, :show, pair(params))

  # One pair's runs, as the page and its JSON show them.
  defp pair(%{"harness_id" => harness_id, "wallet_id" => wallet_id} = params) do
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
    results = Sets.filter(results, filters)
    sets = Sets.build(results, summaries)
    selection = Map.take(params, ~w(set baseline compare))
    validate_selection!(selection, sets)

    comparison = Sets.compare(sets, selection["baseline"], selection["compare"], checks)

    stopped = Matrix.stopped_at(results)
    shown = Enum.find(sets, &(&1.id == selection["set"]))

    if shown && shown.grid != test, do: raise(NotFoundError)

    results = in_set(results, shown)

    selected_run = selected_run!(results, test, params["run"])
    check = params["check"]
    validate_check!(check, test)
    {report, report_error} = report(selected_run)

    [
      page_title: "Can #{harness.name} use a #{wallet.name} wallet?",
      page_description:
        "How #{harness.name} did with #{wallet.name} on the Agent Wallet Bench: test by test, each run on a fresh machine.",
      harness: harness,
      wallet: wallet,
      notes: Matrix.notes(notes),
      grids: grids(results, checks, fixed, stopped, harness_id, wallet_id),
      sets: sets,
      shown: shown,
      selection: selection,
      comparison: comparison,
      extra_notes:
        extra_notes |> ExtraNotes.by_release([harness, wallet]) |> ExtraNotes.for_runs(results),
      test: test,
      context: context,
      filters: filters,
      selected_run: selected_run,
      report: report,
      report_error: report_error,
      selected_check: check,
      focus: focus(check, selected_run)
    ]
  end

  defp validate_selection!(selection, sets) do
    Enum.each(selection, fn {_key, id} ->
      unless id == "" or Enum.any?(sets, &(&1.id == id)), do: raise(NotFoundError)
    end)
  end

  defp validate_check!(nil, _test), do: :ok

  defp validate_check!(check, test) do
    defined_checks = if test in ["install", "wallet"], do: 9, else: 5
    unless check in Enum.map(1..defined_checks, &"C#{&1}"), do: raise(NotFoundError)
  end

  defp report(nil), do: {nil, false}

  defp report(run) do
    case PublicRun.fetch(run) do
      {:ok, report} -> {report, false}
      {:error, _reason} -> {nil, true}
    end
  end

  defp focus(check, %{decided_by: decided_by}) when is_binary(check) and is_binary(decided_by),
    do: "wb-check-#{decided_by}-#{check}"

  defp focus(_check, _run), do: "recorded-run"

  defp grids(results, checks, fixed, stopped, harness_id, wallet_id) do
    checks = Enum.group_by(checks, &{&1.grid, &1.attempt_id})

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
  end

  defp selected_run!(results, test, nil) do
    results
    |> Enum.filter(&(&1.grid == test))
    |> Enum.max_by(&{DateTime.to_unix(&1.finished_at, :microsecond), &1.attempt_id}, fn -> nil end)
  end

  defp selected_run!(results, test, id) when is_binary(id) do
    run = Enum.find(results, &(&1.grid == test and &1.attempt_id == id))
    run || raise(NotFoundError)
  end

  defp selected_run!(_results, _test, _id), do: raise(NotFoundError)

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
