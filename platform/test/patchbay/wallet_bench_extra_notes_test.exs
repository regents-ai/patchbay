defmodule Patchbay.WalletBench.ExtraNotesTest do
  @moduledoc """
  Techtree's extra notes on a pair's page (`Patchbay.WalletBench.pair_page/1`),
  from rows shaped as Techtree publishes them: each note sits under the
  roster's name for its release, oldest first, only releases the pair's runs
  record are shown, and each run says whether a note is about it.
  """

  # One shared reading for the whole run.
  use Patchbay.DataCase, async: false

  alias Patchbay.Repo
  alias Patchbay.WalletBench
  alias PatchbayTest.SharedBench

  setup do
    SharedBench.forget()
    Req.Test.stub(Patchbay.WalletBench.PublicRun, &Plug.Conn.send_resp(&1, 404, ""))

    Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_roster (kind, id, name)
    VALUES ('harness', 'H1', 'Agent'), ('wallet', 'W1', 'Wallet')
    """)

    run!("H1-W1-a", %{"harness" => "1.0.0", "wallet" => "2.0.0"}, ~N[2026-10-14 01:00:00])
    run!("H1-W1-b", %{"harness" => "1.0.0", "wallet" => nil}, ~N[2026-10-14 02:00:00])
    :ok
  end

  test "notes are listed by release under the roster's name, oldest first, and only on releases the runs record" do
    note!("wallet", "W1", "2.0.0", "wallet", ~N[2026-10-14 03:00:00])
    note!("harness", "H1", "1.0.0", "later", ~N[2026-10-14 02:00:00])
    note!("harness", "H1", "1.0.0", "earlier", ~N[2026-10-14 01:00:00])
    note!("harness", "H1", "1.1.0", "another release", ~N[2026-10-14 01:00:00])
    # An agent's note at a version only the wallet has is about neither.
    note!("harness", "H1", "2.0.0", "the wallet's version", ~N[2026-10-14 01:00:00])
    note!("harness", "H9", "1.0.0", "nobody on the roster", ~N[2026-10-14 01:00:00])
    SharedBench.share!()

    assert {:ok, page} = WalletBench.pair_page(%{"harness_id" => "H1", "wallet_id" => "W1"})

    assert [
             %{kind: "harness", id: "H1", name: "Agent", version: "1.0.0", notes: agent_notes},
             %{kind: "wallet", id: "W1", name: "Wallet", version: "2.0.0", notes: [_wallet_note]}
           ] = page[:extra_notes]

    assert Enum.map(agent_notes, & &1.note) == ~w(earlier later)
  end

  test "each run says whether a note is about a release it records" do
    note!("wallet", "W1", "2.0.0", "wallet", ~N[2026-10-14 03:00:00])
    SharedBench.share!()

    assert {:ok, page} = WalletBench.pair_page(%{"harness_id" => "H1", "wallet_id" => "W1"})
    %{runs: runs} = Enum.find(page[:grids], &(&1.grid == "install"))

    assert Map.new(runs, &{&1.result.set_id, &1.noted?}) == %{
             "H1-W1-a" => true,
             "H1-W1-b" => false
           }
  end

  test "a pair whose runs record no noted release shows none" do
    note!("harness", "H1", "1.1.0", "another release", ~N[2026-10-14 01:00:00])
    SharedBench.share!()

    assert {:ok, page} = WalletBench.pair_page(%{"harness_id" => "H1", "wallet_id" => "W1"})
    assert page[:extra_notes] == []
  end

  # One install run of H1 with W1 in a set of its own, recording `versions`.
  defp run!(set_id, versions, finished_at) do
    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_results
        (attempt_id, grid, harness_id, wallet_id, run, outcome, decided_by, turns, run_url,
         set_versions, set_id, finished_at)
      VALUES ($1, 'install', 'H1', 'W1', 1, 'PASS', 'T1a', '[]', 'https://techtree.sh/run',
              $2, $3, $4)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), versions, set_id, finished_at]
    )

    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_pair_summary
        (set_id, harness_id, wallet_id, grid, current, runs, successes, caveat_runs, proof_kind,
         last_run_at)
      VALUES ($1, 'H1', 'W1', 'install', true, 1, 1, 0, 'judge', $2)
      """,
      [set_id, finished_at]
    )
  end

  defp note!(kind, id, version, note, noted_at) do
    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_extra_notes (kind, id, version, note, noted_at)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [kind, id, version, note, noted_at]
    )
  end
end
