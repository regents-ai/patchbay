defmodule Patchbay.WalletBench.Matrix do
  @moduledoc """
  The bench's grids, one for each test, agents by wallets, built from what
  Techtree publishes.

  Each square holds the outcomes of the pair's current set when it matches
  the filters, otherwise its newest matching set, counted separately (two passes and an inconclusive run stay two and
  one, never one verdict), the
  fixed outcome Techtree gives a square that never runs, and one dot for each
  of the grid's checks: in how many of the pair's runs that reached the test
  the judge found it held.
  A wallet square with no runs stopped at install when the pair's latest
  install run did not pass; any other square with no runs and no fixed
  outcome has not been tested yet.

  The zoomable board also has a separate presentation of the latest matching
  attempt, across all of the pair's sets. Its nine positions never combine
  checks from different attempts. Money grids publish five checks, so their
  last four positions are explicitly not applicable. A newer failed install
  takes precedence over an older wallet result, while the recorded set counts
  and history stay intact.

  The last three grids are the money tests. Techtree gives every finished
  money run a result in each of them, so a money square with no runs has
  simply not been tested yet. A run that never reached a money test is ruled
  not run, with the reason, and has no deciding step and no checks: it counts
  among the square's runs and outcomes, and not in its dots.
  """

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.ExtraNotes
  alias Patchbay.WalletBench.Sets

  @grids ["install", "wallet", "refund", "paid_call", "patchbay"]
  @display_criteria ~w(C1 C2 C3 C4 C5 C6 C7 C8 C9)

  # Every outcome Techtree rules, in the order the page lists them.
  @outcomes ~w(PASS PASS* FAILED_TECHNICAL FAILED_SAFETY BLOCKED_AUTH BLOCKED_POLICY
               BLOCKED_ENVIRONMENT BLOCKED_UPSTREAM WAITING_HUMAN INCONCLUSIVE NOT_RUN)

  @type criterion :: %{id: String.t(), criterion: String.t()}
  @type dot :: %{criterion: criterion(), held: non_neg_integer()}
  @type display_dot :: %{
          criterion: criterion(),
          result: String.t(),
          reason: String.t() | nil
        }
  @type square :: %{
          runs: non_neg_integer(),
          judged: non_neg_integer(),
          tally: [{String.t(), pos_integer()}],
          fixed: [struct()],
          dots: [dot()],
          stopped: %{set_id: String.t()} | nil,
          display_run: struct() | nil,
          display_set_id: String.t() | nil,
          display_dots: [display_dot()],
          newer_install_failure: struct() | nil
        }

  @passed ~w(PASS PASS*)

  @doc "Every outcome Techtree rules, in the order the page lists them."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "The grids Techtree runs, in the order the page shows them."
  @spec grids() :: [String.t()]
  def grids, do: @grids

  @doc """
  Everything the page shows, read now: the agents and wallets, Techtree's
  notes by key, its extra notes by release, and for each grid its checks and
  its squares by `{harness_id, wallet_id}`.
  """
  @spec read() :: {:ok, map()} | {:error, term()}
  @spec read(map()) :: {:ok, map()} | {:error, term()}
  def read(filters \\ %{}) do
    with {:ok, roster} <- WalletBench.list_roster(),
         {:ok, notes} <- WalletBench.list_notes(),
         {:ok, fixed} <- WalletBench.list_fixed(),
         {:ok, results} <- WalletBench.list_results(),
         {:ok, summaries} <- WalletBench.list_sets(),
         {:ok, checks} <- WalletBench.list_checks(),
         {:ok, extra_notes} <- WalletBench.list_extra_notes() do
      {:ok,
       roster
       |> build(notes, fixed, results, summaries, checks, filters)
       |> Map.put(:extra_notes, ExtraNotes.by_release(extra_notes, roster))}
    end
  end

  @doc "Techtree's notes by key."
  @spec notes([struct()]) :: %{String.t() => String.t()}
  def notes(notes), do: Map.new(notes, &{&1.key, &1.text})

  @doc "The page's grids from the views' rows."
  @spec build([struct()], [struct()], [struct()], [struct()], [struct()], [struct()]) :: map()
  @spec build([struct()], [struct()], [struct()], [struct()], [struct()], [struct()], map()) ::
          map()
  def build(roster, notes, fixed, results, summaries, checks, filters \\ %{}) do
    options = Sets.options(results)
    results = Sets.filter(results, filters)
    roster = Enum.sort_by(roster, & &1.id)
    harnesses = Enum.filter(roster, &(&1.kind == "harness"))
    wallets = Enum.filter(roster, &(&1.kind == "wallet"))
    installs = Enum.group_by(results, &{&1.harness_id, &1.wallet_id})

    by_square =
      results
      |> Sets.build(summaries)
      |> Enum.group_by(&{&1.grid, &1.summary.harness_id, &1.summary.wallet_id})

    found = Map.new(checks, &{{&1.grid, &1.attempt_id, &1.criterion_id}, &1.result})
    published = Map.new(checks, &{{&1.grid, &1.attempt_id, &1.criterion_id}, &1})

    grids =
      Enum.map(@grids, fn grid ->
        criteria = criteria(checks, grid)

        squares =
          for h <- harnesses, w <- wallets, into: %{} do
            sets = Map.get(by_square, {grid, h.id, w.id}, [])
            fixed = fixed_for(fixed, grid, h.id, w.id)
            runs = Map.get(installs, {h.id, w.id}, [])

            square =
              sets
              |> shown_square(fixed, criteria, found)
              |> Map.put(:stopped, stopped(grid, sets, fixed, runs))
              |> Map.merge(presentation(grid, sets, fixed, runs, published))

            {{h.id, w.id}, square}
          end

        %{grid: grid, criteria: criteria, squares: squares}
      end)

    visible_wallets =
      Enum.reject(wallets, fn wallet ->
        harnesses != [] and
          Enum.all?(grids, fn grid ->
            Enum.all?(harnesses, &placeholder?(grid.squares[{&1.id, wallet.id}]))
          end)
      end)

    grids =
      Enum.map(grids, fn grid ->
        visible_harnesses =
          Enum.reject(harnesses, fn harness ->
            wallets != [] and
              Enum.all?(wallets, &placeholder?(grid.squares[{harness.id, &1.id}]))
          end)

        squares =
          for h <- visible_harnesses, w <- visible_wallets, into: %{} do
            {{h.id, w.id}, grid.squares[{h.id, w.id}]}
          end

        grid
        |> Map.put(:harnesses, visible_harnesses)
        |> Map.put(:squares, squares)
        |> Map.merge(progress(squares))
      end)

    %{
      wallets: visible_wallets,
      notes: notes(notes),
      grids: grids,
      options: options,
      filters: filters
    }
  end

  @doc """
  The install run a pair's wallet test stopped at: its latest install run,
  when that did not pass, no wallet run came from it, and no newer wallet
  result supersedes it. Techtree runs the wallet test only after the install
  test passes. Callers apply any cohort filters before passing the runs.
  """
  @spec stopped_at([struct()]) :: struct() | nil
  def stopped_at(runs) do
    installs = Enum.filter(runs, &(&1.grid == "install"))
    wallets = Enum.filter(runs, &(&1.grid == "wallet"))
    latest = latest_run(installs)

    if latest && latest.outcome not in @passed &&
         not Enum.any?(wallets, &(&1.attempt_id == latest.attempt_id)) &&
         newer_than?(latest, latest_run(wallets)),
       do: latest
  end

  # A wallet square with nothing to show links to the install runs it
  # stopped at.
  defp stopped("wallet", [], [], runs) do
    if run = stopped_at(runs), do: %{set_id: run.set_id}
  end

  defp stopped(_grid, _sets, _fixed, _runs), do: nil

  @doc "The fixed outcomes that apply to one square, from Techtree's `\"*\"` keys."
  @spec fixed_for([struct()], String.t(), String.t(), String.t()) :: [struct()]
  def fixed_for(fixed, grid, harness_id, wallet_id) do
    Enum.filter(fixed, fn f ->
      f.grid in ["*", grid] and f.harness_id in ["*", harness_id] and
        f.wallet_id in ["*", wallet_id]
    end)
  end

  @doc """
  Techtree's short word for an outcome: its note up to the first colon or
  full stop, so "Pass: all five checks held." reads "Pass".
  """
  @spec word(%{String.t() => String.t()}, String.t()) :: String.t()
  def word(notes, outcome) do
    notes |> Map.fetch!(outcome) |> String.split([":", "."], parts: 2) |> hd()
  end

  # A grid's checks, in Techtree's order.
  defp criteria(checks, grid) do
    checks
    |> Enum.filter(&(&1.grid == grid))
    |> Enum.uniq_by(& &1.criterion_id)
    |> Enum.sort_by(& &1.criterion_id)
    |> Enum.map(&%{id: &1.criterion_id, criterion: &1.criterion})
  end

  # A square counts only the runs of the first of its sets, the pair's current
  # one unless a filter leaves it out, and says which set that is and how many
  # sets the pair has.
  defp shown_square(sets, fixed, criteria, found) do
    shown = List.first(sets)
    runs = if shown, do: shown.runs, else: []

    runs
    |> square(fixed, criteria, found)
    |> Map.merge(%{set_id: shown && shown.id, set_count: length(sets)})
  end

  defp square(runs, fixed, criteria, found) do
    tally =
      runs
      |> Enum.frequencies_by(& &1.outcome)
      |> Enum.sort_by(fn {outcome, _count} -> Enum.find_index(@outcomes, &(&1 == outcome)) end)

    dots =
      Enum.map(criteria, fn criterion ->
        held = Enum.count(runs, &(found[{&1.grid, &1.attempt_id, criterion.id}] == "true"))
        %{criterion: criterion, held: held}
      end)

    %{
      runs: length(runs),
      judged: Enum.count(runs, & &1.decided_by),
      tally: tally,
      fixed: fixed,
      dots: dots
    }
  end

  # Aggregates keep Techtree's selected set. Presentation chooses one latest
  # matching attempt, so a current-but-older set cannot hide a newer result.
  defp presentation(grid, sets, fixed, runs, published) do
    display_run = sets |> Enum.flat_map(& &1.runs) |> latest_run()
    failure = if grid == "wallet", do: stopped_at(runs)
    dot_run = if failure, do: nil, else: display_run
    not_run_reason = not_run_reason(display_run, failure, fixed)

    %{
      display_run: display_run,
      display_set_id: display_run && display_run.set_id,
      newer_install_failure: failure,
      display_dots:
        Enum.map(@display_criteria, &display_dot(grid, &1, dot_run, published, not_run_reason))
    }
  end

  # Techtree's money-test rubrics have five criteria. Keep the visual 3x3
  # shape without presenting unused positions as absent or failed evidence.
  defp display_dot(grid, id, _run, _published, _not_run_reason)
       when grid in ~w(refund paid_call patchbay) and id in ~w(C6 C7 C8 C9) do
    %{
      criterion: %{id: id, criterion: "Outside this five-check rubric"},
      result: "not_applicable",
      reason: "This test publishes five checks; this position is display padding."
    }
  end

  defp display_dot(grid, id, run, published, not_run_reason) do
    check = run && published[{grid, run.attempt_id, id}]

    %{
      criterion: %{
        id: id,
        criterion: (check && check.criterion) || "Criterion not recorded"
      },
      result: display_result(check, not_run_reason),
      reason: display_reason(check, run, not_run_reason)
    }
  end

  defp not_run_reason(_run, failure, _fixed) when not is_nil(failure) do
    "Wallet test did not run after the latest install attempt (#{failure.outcome})."
  end

  defp not_run_reason(%{outcome: "NOT_RUN"} = run, _failure, _fixed),
    do: Map.get(run, :outcome_detail) || "Techtree recorded this test as not run."

  defp not_run_reason(nil, _failure, fixed) do
    case Enum.find(fixed, &(&1.fixed_outcome == "NOT_RUN")) do
      nil -> nil
      reason -> reason.fixed_reason
    end
  end

  defp not_run_reason(_run, _failure, _fixed), do: nil

  defp display_result(_check, reason) when not is_nil(reason), do: "not_run"

  defp display_result(%{result: result}, _reason)
       when result in ["true", "false", "open", "not_run"],
       do: result

  defp display_result(_check, _reason), do: "missing"

  defp display_reason(_check, _run, reason) when not is_nil(reason), do: reason

  defp display_reason(%{reason: reason}, _run, _not_run_reason) when not is_nil(reason),
    do: reason

  defp display_reason(nil, nil, _reason), do: "No matching run has been published for this pair."

  defp display_reason(check, _run, _reason) do
    if display_result(check, nil) == "missing",
      do: "No check result was published for this attempt."
  end

  defp latest_run([]), do: nil
  defp latest_run(runs), do: Enum.max_by(runs, &chronology/1)

  defp newer_than?(_run, nil), do: true
  defp newer_than?(run, prior), do: chronology(run) > chronology(prior)

  # Techtree orders attempts by timestamp then UUID. Run numbers are local to
  # each grid, so comparing those across install and wallet would be wrong.
  defp chronology(run), do: {DateTime.to_unix(run.finished_at, :microsecond), run.attempt_id}

  defp placeholder?(square) do
    square.runs == 0 and square.fixed != [] and
      Enum.all?(square.fixed, &(&1.fixed_outcome in ["WAITING_HUMAN", "NOT_RUN"]))
  end

  defp progress(squares) do
    squares = Map.values(squares)

    %{
      total: length(squares),
      tested: Enum.count(squares, &(&1.runs > 0)),
      never_run: Enum.count(squares, &(&1.runs == 0 and &1.fixed != []))
    }
  end
end
