defmodule PatchbayWeb.WalletBenchMD do
  @moduledoc "The Agent Wallet Bench grids and one pair's runs as markdown."

  use PatchbayWeb, :md

  import PatchbayWeb.WalletBenchHTML,
    only: [
      grid_title: 1,
      word: 2,
      outcomes: 0,
      check_said: 1,
      versions: 1,
      steps?: 1,
      deciding_step: 1,
      plain_file: 1
    ]

  embed_templates("wallet_bench_md/*")

  @doc "A grid as a markdown table, each cell what the square shows."
  def grid_table(matrix, grid) do
    head = row(["" | Enum.map(matrix.wallets, & &1.name)])
    rule = row(Enum.map(0..length(matrix.wallets), fn _ -> "---" end))

    body =
      for h <- matrix.harnesses do
        row([
          h.name
          | Enum.map(matrix.wallets, fn w ->
              cell(matrix.notes, grid.squares[{h.id, w.id}], h, w)
            end)
        ])
      end

    Enum.join([head, rule | body], "\n")
  end

  defp cell(_notes, %{runs: 0, fixed: []}, _h, _w), do: "not tested yet"

  defp cell(notes, square, h, w) do
    outcomes =
      Enum.map(square.tally, fn {outcome, n} ->
        "#{word(notes, outcome)} #{n} of #{square.runs}"
      end) ++
        (square.fixed |> Enum.map(&word(notes, &1.fixed_outcome)) |> Enum.uniq())

    Enum.join(outcomes, "; ") <> " ([runs](/wallet-bench/#{h.id}/#{w.id}))"
  end
end
