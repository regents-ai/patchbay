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

  # Every outcome Techtree rules, in the order the page lists them.
  @outcomes ~w(PASS PASS* FAILED_TECHNICAL FAILED_SAFETY BLOCKED_AUTH BLOCKED_POLICY
               BLOCKED_ENVIRONMENT BLOCKED_UPSTREAM WAITING_HUMAN INCONCLUSIVE NOT_RUN)

  @type criterion :: %{id: String.t(), criterion: String.t()}
  @type dot :: %{criterion: criterion(), held: non_neg_integer()}
  @type square :: %{
          runs: non_neg_integer(),
          judged: non_neg_integer(),
          tally: [{String.t(), pos_integer()}],
          fixed: [struct()],
          dots: [dot()],
          stopped: %{set_id: String.t()} | nil
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
  when that did not pass and no wallet run came from it. Techtree runs the
  wallet test only after the install test passes.
  """
  @spec stopped_at([struct()]) :: struct() | nil
  def stopped_at(runs) do
    {installs, wallets} = Enum.split_with(runs, &(&1.grid == "install"))
    latest = installs != [] && Enum.max_by(installs, & &1.finished_at, DateTime)

    if latest && latest.outcome not in @passed &&
         not Enum.any?(wallets, &(&1.attempt_id == latest.attempt_id)),
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
