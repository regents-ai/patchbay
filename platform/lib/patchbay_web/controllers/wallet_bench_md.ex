defmodule PatchbayWeb.WalletBenchMD do
  @moduledoc "The Agent Wallet Bench grids, how the bench works, and one pair's runs as markdown."

  use PatchbayWeb, :md

  alias Patchbay.Forum.ProgramSites
  alias Patchbay.WalletBench.Sets

  import PatchbayWeb.WalletBenchHTML,
    only: [
      grid_title: 1,
      empty_grid: 1,
      word: 2,
      outcomes: 0,
      results: 0,
      results_total: 0,
      check_said: 1,
      versions: 1,
      forums: 2,
      threads_path: 2,
      ask_about_path: 2,
      square_path: 5,
      set_facts: 1,
      steps?: 1,
      deciding_step: 1,
      plain_file: 1
    ]

  embed_templates("wallet_bench_md/*")

  @doc "A grid as a markdown table, each cell what the square shows."
  def grid_table(matrix, grid) do
    head = row(["" | Enum.map(matrix.wallets, &entry_link/1)])
    rule = row(Enum.map(0..length(matrix.wallets), fn _ -> "---" end))

    body =
      for h <- grid.harnesses do
        row([
          entry_link(h)
          | Enum.map(matrix.wallets, fn w ->
              square = grid.squares[{h.id, w.id}]
              path = square_path(square, h, w, grid.grid, matrix.filters)
              cell(matrix.notes, square) <> " ([runs](#{path}))"
            end)
        ])
      end

    Enum.join([head, rule | body], "\n")
  end

  defp entry_link(entry) do
    case ProgramSites.domain(entry) do
      nil -> line(entry.name)
      domain -> "[#{line(entry.name)}](/#{domain})"
    end
  end

  defp cell(_notes, %{runs: 0, fixed: [], stopped: %{}}), do: "stopped at install"

  defp cell(_notes, %{runs: 0, fixed: []}), do: "not tested yet"

  defp cell(notes, square) do
    outcomes =
      Enum.map(square.tally, fn {outcome, n} ->
        "#{word(notes, outcome)} #{n} of #{square.runs}"
      end) ++
        (square.fixed |> Enum.map(&word(notes, &1.fixed_outcome)) |> Enum.uniq())

    Enum.join(outcomes, "; ")
  end
end
