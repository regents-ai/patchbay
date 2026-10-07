defmodule Patchbay.WalletBench.Matrix do
  @moduledoc """
  The bench's two grids, agents by wallets, built from what Techtree publishes.

  Each square holds the outcomes of that pair's runs counted separately (two
  passes and an inconclusive run stay two and one, never one verdict), how
  many came from a second install try or a signature request, the plain files
  behind a flagged pass, and the fixed outcome Techtree gives a square that
  never runs. A square with no runs and no fixed outcome has not been tested
  yet.
  """

  alias Patchbay.WalletBench

  @grids ["install", "wallet"]

  # Every outcome Techtree rules, in the order the page lists them.
  @outcomes ~w(PASS PASS* FAILED_TECHNICAL FAILED_SAFETY BLOCKED_AUTH BLOCKED_POLICY
               BLOCKED_ENVIRONMENT BLOCKED_UPSTREAM WAITING_HUMAN INCONCLUSIVE NOT_RUN)

  @type square :: %{
          runs: non_neg_integer(),
          tally: [{String.t(), pos_integer()}],
          fixed: [struct()],
          second_tries: non_neg_integer(),
          signatures: non_neg_integer(),
          plain_files: [String.t()]
        }

  @doc "Every outcome Techtree rules, in the order the page lists them."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "The grids Techtree runs, in the order the page shows them."
  @spec grids() :: [String.t()]
  def grids, do: @grids

  @doc """
  Everything the page shows, read now: the agents and wallets, Techtree's
  notes by key, and for each grid its squares by `{harness_id, wallet_id}`.
  """
  @spec read() :: {:ok, map()} | {:error, term()}
  def read do
    with {:ok, roster} <- WalletBench.list_roster(),
         {:ok, notes} <- WalletBench.list_notes(),
         {:ok, fixed} <- WalletBench.list_fixed(),
         {:ok, results} <- WalletBench.list_results() do
      {:ok, build(roster, notes, fixed, results)}
    end
  end

  @doc "Techtree's notes by key."
  @spec notes([struct()]) :: %{String.t() => String.t()}
  def notes(notes), do: Map.new(notes, &{&1.key, &1.text})

  @doc "The page's grids from the views' rows."
  @spec build([struct()], [struct()], [struct()], [struct()]) :: map()
  def build(roster, notes, fixed, results) do
    roster = Enum.sort_by(roster, & &1.id)
    harnesses = Enum.filter(roster, &(&1.kind == "harness"))
    wallets = Enum.filter(roster, &(&1.kind == "wallet"))
    by_square = Enum.group_by(results, &{&1.grid, &1.harness_id, &1.wallet_id})

    %{
      harnesses: harnesses,
      wallets: wallets,
      notes: notes(notes),
      grids:
        Enum.map(@grids, fn grid ->
          squares =
            for h <- harnesses, w <- wallets, into: %{} do
              runs = Map.get(by_square, {grid, h.id, w.id}, [])
              {{h.id, w.id}, square(runs, fixed_for(fixed, grid, h.id, w.id))}
            end

          %{grid: grid, squares: squares} |> Map.merge(progress(squares))
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

  defp square(runs, fixed) do
    tally =
      runs
      |> Enum.frequencies_by(& &1.outcome)
      |> Enum.sort_by(fn {outcome, _count} -> Enum.find_index(@outcomes, &(&1 == outcome)) end)

    %{
      runs: length(runs),
      tally: tally,
      fixed: fixed,
      second_tries: Enum.count(runs, & &1.second_try),
      signatures: Enum.count(runs, & &1.signature_asked),
      plain_files:
        runs |> Enum.map(& &1.plain_file) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    }
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
