defmodule PatchbayWeb.WalletBenchJSONTest do
  @moduledoc "The bench board as agents read it: the whole board is one tool answer."

  use ExUnit.Case, async: true

  alias Patchbay.WalletBench.Matrix
  alias PatchbayWeb.WalletBenchJSON

  @finished ~U[2026-10-13 12:00:00.000000Z]
  @reason String.duplicate("The judge's recorded reason for this check. ", 6)

  # Twice today's roster, every square judged on all nine checks with long
  # reasons, details and versions, as Techtree publishes them.
  test "a board twice today's size fits one 128 KiB agent tool answer" do
    harnesses =
      for n <- 1..20,
          do: %{
            id: "H#{n}",
            kind: "harness",
            name: "Agent #{n}",
            website: "https://agent#{n}.example"
          }

    wallets =
      for n <- 1..4,
          do: %{
            id: "W#{n}",
            kind: "wallet",
            name: "Wallet #{n}",
            website: "https://wallet#{n}.example"
          }

    runs = for h <- harnesses, w <- wallets, do: run(h.id, w.id)

    checks =
      for run <- runs, n <- 1..9 do
        %{
          grid: "install",
          attempt_id: run.attempt_id,
          criterion_id: "C#{n}",
          criterion: "Published check #{n}",
          result: "true",
          reason: @reason
        }
      end

    matrix =
      harnesses
      |> Kernel.++(wallets)
      |> Matrix.build([], [], runs, Enum.map(runs, &summary/1), checks)
      |> Map.put(:extra_notes, [])

    board =
      WalletBenchJSON.index(%{
        matrix: matrix,
        test: Enum.find(matrix.grids, &(&1.grid == "install"))
      })

    assert board.schema_version == 3
    assert length(board.squares) == 80
    assert byte_size(Jason.encode!(board)) < 128 * 1024

    square = hd(board.squares)
    assert square.checks == Map.new(1..9, &{"C#{&1}", "true"})
    assert square.repeated_set.checks == Map.new(1..9, &{"C#{&1}", 1})
    refute Map.has_key?(square.latest_attempt, :outcome_detail)
    refute Map.has_key?(square.latest_attempt, :set_versions)
  end

  defp run(harness_id, wallet_id) do
    %{
      attempt_id: Ecto.UUID.generate(),
      grid: "install",
      harness_id: harness_id,
      wallet_id: wallet_id,
      run: 1,
      outcome: "PASS",
      outcome_detail: @reason,
      plain_file: nil,
      decided_by: "T1a",
      set_id: :crypto.hash(:sha256, harness_id <> wallet_id) |> Base.encode16(case: :lower),
      set_versions: %{harness: "0.21.6", model: "claude-opus-5-5", wallet: "0.3.45"},
      run_url: "https://techtree.sh/wallet-bench/" <> Ecto.UUID.generate(),
      finished_at: @finished
    }
  end

  defp summary(run) do
    %{
      set_id: run.set_id,
      harness_id: run.harness_id,
      wallet_id: run.wallet_id,
      current: true,
      last_run_at: run.finished_at
    }
  end
end
