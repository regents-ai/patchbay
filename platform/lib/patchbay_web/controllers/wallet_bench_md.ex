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
      square_path: 5,
      square_summary: 2,
      dot_answer: 1,
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
              cell(matrix.notes, square) <> " ([inspect run](#{path}))"
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

  defp cell(notes, square) do
    checks =
      Enum.map_join(square.display_dots, "; ", &"#{&1.criterion.id} #{dot_answer(&1.result)}")

    line(square_summary(notes, square)) <> ". " <> checks
  end
end
