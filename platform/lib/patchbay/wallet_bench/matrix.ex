defmodule Patchbay.WalletBench.Matrix do
  @moduledoc """
  The bench's two grids, agents by wallets, built from what Techtree publishes.

  Each square holds the outcomes of that pair's runs counted separately (two
  passes and an inconclusive run stay two and one, never one verdict), the
  fixed outcome Techtree gives a square that never runs, and one cell for each
  of the grid's checks. A cell holds one dot per run, in run order: what the
  judge found for that check in that run, or nothing when the run has not
  happened. A square with no runs and no fixed outcome has not been tested yet.
  """

  alias Patchbay.WalletBench

  @grids ["install", "wallet"]

  # Every outcome Techtree rules, in the order the page lists them.
  @outcomes ~w(PASS PASS* FAILED_TECHNICAL FAILED_SAFETY BLOCKED_AUTH BLOCKED_POLICY
               BLOCKED_ENVIRONMENT BLOCKED_UPSTREAM WAITING_HUMAN INCONCLUSIVE NOT_RUN)

  # Each pair runs three times (Techtree's "runs" note), so a cell has a dot for
  # each of the three.
  @runs_per_pair 3

  @type criterion :: %{id: String.t(), criterion: String.t()}
  @type cell :: %{criterion: criterion(), dots: [String.t() | nil]}
  @type square :: %{
          runs: non_neg_integer(),
          tally: [{String.t(), pos_integer()}],
          fixed: [struct()],
          cells: [cell()]
        }

  @doc "Every outcome Techtree rules, in the order the page lists them."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "The grids Techtree runs, in the order the page shows them."
  @spec grids() :: [String.t()]
  def grids, do: @grids

  @doc """
  Everything the page shows, read now: the agents and wallets, Techtree's
  notes by key, and for each grid its checks and its squares by
  `{harness_id, wallet_id}`.
  """
  @spec read() :: {:ok, map()} | {:error, term()}
  def read do
    with {:ok, roster} <- WalletBench.list_roster(),
         {:ok, notes} <- WalletBench.list_notes(),
         {:ok, fixed} <- WalletBench.list_fixed(),
         {:ok, results} <- WalletBench.list_results(),
         {:ok, checks} <- WalletBench.list_checks() do
      {:ok, build(roster, notes, fixed, results, checks)}
    end
  end

  @doc "Techtree's notes by key."
  @spec notes([struct()]) :: %{String.t() => String.t()}
  def notes(notes), do: Map.new(notes, &{&1.key, &1.text})

  @doc "The page's grids from the views' rows."
  @spec build([struct()], [struct()], [struct()], [struct()], [struct()]) :: map()
  def build(roster, notes, fixed, results, checks) do
    roster = Enum.sort_by(roster, & &1.id)
    harnesses = Enum.filter(roster, &(&1.kind == "harness"))
    wallets = Enum.filter(roster, &(&1.kind == "wallet"))
    by_square = Enum.group_by(results, &{&1.grid, &1.harness_id, &1.wallet_id})
    found = Map.new(checks, &{{&1.grid, &1.attempt_id, &1.criterion_id}, &1.result})

    %{
      harnesses: harnesses,
      wallets: wallets,
      notes: notes(notes),
      grids:
        Enum.map(@grids, fn grid ->
          criteria = criteria(checks, grid)

          squares =
            for h <- harnesses, w <- wallets, into: %{} do
              runs = by_square |> Map.get({grid, h.id, w.id}, []) |> Enum.sort_by(& &1.run)
              fixed = fixed_for(fixed, grid, h.id, w.id)
              {{h.id, w.id}, square(runs, fixed, criteria, found)}
            end

          %{grid: grid, criteria: criteria, squares: squares} |> Map.merge(progress(squares))
        end)
    }
  end

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

  defp square(runs, fixed, criteria, found) do
    tally =
      runs
      |> Enum.frequencies_by(& &1.outcome)
      |> Enum.sort_by(fn {outcome, _count} -> Enum.find_index(@outcomes, &(&1 == outcome)) end)

    cells =
      Enum.map(criteria, fn criterion ->
        dots = Enum.map(runs, &found[{&1.grid, &1.attempt_id, criterion.id}])

        %{
          criterion: criterion,
          dots: dots ++ List.duplicate(nil, max(@runs_per_pair - length(runs), 0))
        }
      end)

    %{runs: length(runs), tally: tally, fixed: fixed, cells: cells}
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
