defmodule Patchbay.WalletBench.MatrixTest do
  @moduledoc "The Wallet Bench boards, built from rows shaped as Techtree publishes them."

  use ExUnit.Case, async: true

  alias Patchbay.WalletBench.Matrix

  @finished ~U[2026-10-13 12:00:00.000000Z]

  test "a run that never reached a money test counts among the square's runs and outcomes, and not in its dots" do
    roster = [
      %{id: "H1", kind: "harness", name: "Agent"},
      %{id: "W1", kind: "wallet", name: "Wallet"}
    ]

    reached = run("paid_call", Ecto.UUID.generate(), 1, "PASS", "T4")
    never = run("paid_call", Ecto.UUID.generate(), 2, "NOT_RUN", nil)

    summary = %{
      set_id: "set",
      harness_id: "H1",
      wallet_id: "W1",
      current: true,
      last_run_at: @finished
    }

    checks =
      for id <- ~w(C1 C2) do
        %{
          grid: "paid_call",
          attempt_id: reached.attempt_id,
          criterion_id: id,
          criterion: id,
          result: "true"
        }
      end

    %{grids: grids} = Matrix.build(roster, [], [], [reached, never], [summary], checks)

    assert Enum.map(grids, & &1.grid) == ~w(install wallet refund paid_call patchbay)

    paid_call = Enum.find(grids, &(&1.grid == "paid_call"))
    square = paid_call.squares[{"H1", "W1"}]

    assert %{runs: 2, judged: 1, tally: [{"PASS", 1}, {"NOT_RUN", 1}]} = square
    assert Enum.map(square.dots, & &1.held) == [1, 1]

    # The same pair's other money boards have nothing yet.
    refund = Enum.find(grids, &(&1.grid == "refund"))
    assert %{runs: 0, judged: 0, stopped: nil} = refund.squares[{"H1", "W1"}]
  end

  defp run(grid, attempt_id, run, outcome, decided_by) do
    %{
      attempt_id: attempt_id,
      grid: grid,
      harness_id: "H1",
      wallet_id: "W1",
      run: run,
      outcome: outcome,
      decided_by: decided_by,
      set_id: "set",
      set_versions: %{},
      finished_at: @finished
    }
  end
end
