defmodule Patchbay.WalletBench.MatrixTest do
  @moduledoc "The Wallet Bench boards, built from rows shaped as Techtree publishes them."

  use ExUnit.Case, async: true

  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.Sets

  @finished ~U[2026-10-13 12:00:00.000000Z]
  @older "00000000-0000-0000-0000-000000000001"
  @newer "00000000-0000-0000-0000-000000000002"
  @roster [
    %{id: "H1", kind: "harness", name: "Agent"},
    %{id: "W1", kind: "wallet", name: "Wallet"}
  ]

  test "a run that never reached a money test counts among the square's runs and outcomes, and not in its dots" do
    roster = [
      %{id: "H1", kind: "harness", name: "Agent"},
      %{id: "W1", kind: "wallet", name: "Wallet"}
    ]

    reached = run("paid_call", @older, 1, "PASS", "T4")
    never = run("paid_call", @newer, 2, "NOT_RUN", nil)

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

    %{grids: grids} =
      Matrix.build(roster, [], [], [reached, never], [summary], checks, criteria(checks))

    assert Enum.map(grids, & &1.grid) == ~w(install wallet refund paid_call patchbay)

    paid_call = Enum.find(grids, &(&1.grid == "paid_call"))
    square = paid_call.squares[{"H1", "W1"}]

    assert %{runs: 2, judged: 1, tally: [{"PASS", 1}, {"NOT_RUN", 1}]} = square
    assert Enum.map(square.dots, & &1.held) == [1, 1]
    assert square.display_run == never

    assert Enum.map(square.display_dots, & &1.result) ==
             List.duplicate("not_run", 5) ++ List.duplicate("not_applicable", 4)

    # The same pair's other money boards have nothing yet.
    refund = Enum.find(grids, &(&1.grid == "refund"))
    assert %{runs: 0, judged: 0, stopped: nil} = refund.squares[{"H1", "W1"}]
  end

  test "an empty board still has nine positions without inventing check names or outcomes" do
    %{grids: grids} = Matrix.build(@roster, [], [], [], [], [], [])

    for grid <- grids do
      square = grid.squares[{"H1", "W1"}]

      assert square.display_run == nil
      assert square.display_set_id == nil
      assert square.newer_install_failure == nil
      assert square.dots == []
      assert Enum.map(square.display_dots, & &1.criterion.id) == ~w(C1 C2 C3 C4 C5 C6 C7 C8 C9)

      count = if grid.grid in ~w(refund paid_call patchbay), do: 5, else: 9
      {checks, padding} = Enum.split(square.display_dots, count)
      assert Enum.all?(checks, &(&1.criterion.criterion == "Criterion not recorded"))
      assert Enum.all?(checks, &(&1.result == "missing"))

      assert Enum.all?(padding, fn dot ->
               dot.result == "not_applicable" &&
                 dot.criterion.criterion == "Outside this five-check rubric"
             end)
    end
  end

  test "one attempt supplies all displayed dots while the set keeps its separate counts" do
    older = run("wallet", @older, 1, "FAILED_TECHNICAL", "T2")
    newer = run("wallet", @newer, 2, "INCONCLUSIVE", "T2")

    checks = [
      check(older, "C1", "true", "An older description"),
      check(older, "C2", "false"),
      check(newer, "C1", "false", "The published current description", "Evidence did not match"),
      check(newer, "C2", "true", "A confirmed check", "Confirmed independently"),
      check(newer, "C3", "open", "An unresolved check", "More evidence needed"),
      check(newer, "C4", nil, "A check with no result", "The judge did not record a value")
    ]

    square = build_square("wallet", [older, newer], checks)

    assert %{runs: 2, judged: 2, set_id: "set", set_count: 1} = square
    assert square.tally == [{"FAILED_TECHNICAL", 1}, {"INCONCLUSIVE", 1}]
    assert Enum.map(square.dots, & &1.held) == [1, 1, 0, 0]
    assert square.display_run == newer

    assert Enum.map(square.display_dots, & &1.result) ==
             ~w(false true open missing missing missing missing missing missing)

    assert hd(square.display_dots) == %{
             criterion: %{id: "C1", criterion: "The published current description"},
             result: "false",
             reason: "Evidence did not match"
           }

    assert Enum.at(square.display_dots, 3).reason == "The judge did not record a value"
  end

  test "an older protocol missing C6 through C9 stays missing even if another attempt has them" do
    selected = run("wallet", @older, 1, "PASS", "T2")
    other = run("wallet", @newer, 2, "PASS", "T2")

    checks =
      Enum.map(~w(C1 C2 C3 C4 C5), &check(selected, &1, "true")) ++
        Enum.map(~w(C6 C7 C8 C9), &check(other, &1, "true", "Another protocol's check"))

    square = build_square("wallet", [selected], checks)

    assert Enum.map(square.display_dots, & &1.result) ==
             ~w(true true true true true missing missing missing missing)

    assert Enum.all?(Enum.drop(square.display_dots, 5), fn dot ->
             dot.criterion.criterion == "Criterion not recorded"
           end)
  end

  test "the latest matching attempt can differ from the current set without changing aggregates" do
    current = run("wallet", @older, 1, "PASS", "T2")

    latest =
      run("wallet", @newer, 2, "FAILED_TECHNICAL", "T2")
      |> Map.merge(%{set_id: "latest-set", finished_at: DateTime.add(@finished, 1, :second)})

    summaries = [summary(current, true), summary(latest, false)]
    checks = [check(current, "C1", "true"), check(latest, "C1", "false")]
    square = build_square("wallet", [current, latest], checks, summaries)

    assert %{runs: 1, judged: 1, tally: [{"PASS", 1}], set_id: "set", set_count: 2} = square
    assert hd(square.dots).held == 1
    assert square.display_run == latest
    assert square.display_set_id == "latest-set"
    assert hd(square.display_dots).result == "false"
  end

  test "a newer failed install across sets supersedes old wallet dots and retains old evidence" do
    wallet = run("wallet", @older, 1, "PASS", "T2")

    failure =
      run("install", @newer, 2, "FAILED_TECHNICAL", "T1b")
      |> Map.merge(%{set_id: "install-set", finished_at: DateTime.add(@finished, 1, :second)})

    square =
      build_square("wallet", [wallet, failure], [check(wallet, "C1", "true")])

    assert %{runs: 1, judged: 1, tally: [{"PASS", 1}], set_id: "set", stopped: nil} = square
    assert square.display_run == wallet
    assert square.newer_install_failure == failure
    assert Enum.all?(square.display_dots, &(&1.result == "not_run"))
    assert Enum.all?(square.display_dots, &String.contains?(&1.reason, "FAILED_TECHNICAL"))
    assert Enum.all?(square.display_dots, &(&1.criterion.criterion == "Criterion not recorded"))
    assert hd(square.dots).held == 1
  end

  test "protocol and model filters apply before the latest attempt and install failure are selected" do
    wallet =
      run("wallet", @older, 1, "PASS", "T2")
      |> Map.put(:set_versions, %{"protocol" => "legacy", "model" => "model-a"})

    failure =
      run("install", @newer, 2, "FAILED_TECHNICAL", "T1b")
      |> Map.merge(%{
        set_id: "install-set",
        set_versions: %{"protocol" => "independent-v2", "model" => "model-b"},
        finished_at: DateTime.add(@finished, 1, :second)
      })

    checks = [check(wallet, "C1", "true")]

    for filters <- [
          %{"protocol" => Sets.token("legacy")},
          %{"model" => Sets.token("model-a")}
        ] do
      square = build_square("wallet", [wallet, failure], checks, nil, filters)

      assert square.display_run == wallet
      assert square.newer_install_failure == nil
      assert hd(square.display_dots).result == "true"
    end

    matrix =
      Matrix.build(
        @roster,
        [],
        [],
        [wallet, failure],
        summaries([wallet, failure]),
        checks,
        criteria(checks)
      )

    assert Enum.map(matrix.options["protocol"], & &1.label) == ["independent-v2", "legacy"]
    assert Enum.map(matrix.options["model"], & &1.label) == ["model-a", "model-b"]
  end

  test "unknown protocol remains an explicit selectable cohort" do
    unknown = run("wallet", @older, 1, "PASS", "T2")

    known =
      run("wallet", @newer, 2, "FAILED_TECHNICAL", "T2")
      |> Map.merge(%{set_id: "known-set", set_versions: %{"protocol" => "independent-v2"}})

    matrix =
      Matrix.build(@roster, [], [], [unknown, known], summaries([unknown, known]), [], [], %{
        "protocol" => Sets.token(nil)
      })

    assert Enum.any?(matrix.options["protocol"], fn option ->
             option.id == Sets.token(nil) && option.label == "Unknown (not recorded)"
           end)

    wallet_grid = Enum.find(matrix.grids, &(&1.grid == "wallet"))
    assert wallet_grid.squares[{"H1", "W1"}].display_run == unknown
  end

  test "same-time selection uses attempt IDs deterministically even when input order reverses" do
    first = run("wallet", @older, 2, "PASS", "T2")
    second = run("wallet", @newer, 1, "FAILED_TECHNICAL", "T2")
    checks = [check(first, "C1", "true"), check(second, "C1", "false")]

    for runs <- [[first, second], [second, first]] do
      square = build_square("wallet", runs, checks)
      assert square.display_run == second
      assert hd(square.display_dots).result == "false"
    end
  end

  test "each check is worded as in its newest run, a same-time tie going to the larger attempt ID" do
    first = run("wallet", @older, 1, "PASS", "T2")
    second = run("wallet", @newer, 2, "PASS", "T2")
    checks = [check(first, "C1", "true", "First wording"), check(second, "C1", "true", "Second")]

    for runs <- [[first, second], [second, first]], checks <- [checks, Enum.reverse(checks)] do
      assert [%{criterion: "Second"}] = Matrix.criteria(checks, runs)

      later_first = %{first | finished_at: DateTime.add(@finished, 1, :microsecond)}

      assert [%{criterion: "First wording"}] =
               Matrix.criteria(checks, [later_first | List.delete(runs, first)])
    end
  end

  test "same-time install failures are compared by attempt ID, not grid-local run numbers" do
    wallet = run("wallet", @older, 80, "PASS", "T2")
    failure = run("install", @newer, 1, "FAILED_TECHNICAL", "T1b")

    assert Matrix.stopped_at([wallet, failure]) == failure
    assert Matrix.stopped_at([failure, wallet]) == failure

    later_wallet = %{wallet | attempt_id: @newer}
    earlier_failure = %{failure | attempt_id: @older}
    assert Matrix.stopped_at([earlier_failure, later_wallet]) == nil
  end

  test "money rows from a failed attempt do not imply that its wallet test ran" do
    failure = run("install", @newer, 1, "FAILED_TECHNICAL", "T1b")
    money = run("paid_call", @newer, 1, "NOT_RUN", nil)

    assert Matrix.stopped_at([money, failure]) == failure
    assert Matrix.stopped_at([failure, money]) == failure
  end

  test "a wallet result from that install attempt suppresses the install warning" do
    failure = run("install", @newer, 1, "FAILED_SAFETY", "T1a")
    wallet = run("wallet", @newer, 1, "FAILED_SAFETY", "T2")

    assert Matrix.stopped_at([failure, wallet]) == nil
  end

  test "a newer passing installation supersedes an old failure without inventing a wallet run" do
    failure = run("install", @older, 1, "FAILED_TECHNICAL", "T1b")
    passing = run("install", @newer, 2, "PASS", "T1a")

    assert Matrix.stopped_at([failure, passing]) == nil
  end

  defp build_square(grid, runs, checks, set_summaries \\ nil, filters \\ %{}) do
    %{grids: grids} =
      Matrix.build(
        @roster,
        [],
        [],
        runs,
        set_summaries || summaries(runs),
        checks,
        criteria(checks),
        filters
      )

    Enum.find(grids, &(&1.grid == grid)).squares[{"H1", "W1"}]
  end

  # Each grid's checks once, as `Matrix.criteria/2` gives them.
  defp criteria(checks) do
    checks
    |> Enum.uniq_by(&{&1.grid, &1.criterion_id})
    |> Enum.sort_by(&{&1.grid, &1.criterion_id})
  end

  defp summaries(runs) do
    runs
    |> Enum.uniq_by(& &1.set_id)
    |> Enum.map(&summary(&1, true))
  end

  defp summary(run, current) do
    %{
      set_id: run.set_id,
      harness_id: run.harness_id,
      wallet_id: run.wallet_id,
      current: current,
      last_run_at: run.finished_at
    }
  end

  defp check(run, id, result, criterion \\ "Published check", reason \\ nil) do
    %{
      grid: run.grid,
      attempt_id: run.attempt_id,
      criterion_id: id,
      criterion: criterion,
      result: result,
      reason: reason
    }
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
