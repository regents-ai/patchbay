defmodule Patchbay.WalletBench.ExtraNotesTest do
  @moduledoc "Techtree's extra notes, put beside releases from rows shaped as Techtree publishes them."

  use ExUnit.Case, async: true

  alias Patchbay.WalletBench.ExtraNotes

  @roster [
    %{kind: "wallet", id: "W1", name: "Wallet"},
    %{kind: "harness", id: "H1", name: "Agent"}
  ]

  test "notes are listed by release under the roster's name, oldest first, and a note about no one on the roster is left out" do
    notes = [
      note("wallet", "W1", "2.0.0", "wallet", ~U[2026-10-14 03:00:00.000000Z]),
      note("harness", "H1", "1.0.0", "later", ~U[2026-10-14 02:00:00.000000Z]),
      note("harness", "H1", "1.0.0", "earlier", ~U[2026-10-14 01:00:00.000000Z]),
      note("harness", "H9", "1.0.0", "nobody", ~U[2026-10-14 01:00:00.000000Z])
    ]

    assert [
             %{kind: "harness", id: "H1", name: "Agent", version: "1.0.0", notes: agent_notes},
             %{kind: "wallet", id: "W1", name: "Wallet", version: "2.0.0", notes: [_wallet_note]}
           ] = ExtraNotes.by_release(notes, @roster)

    assert Enum.map(agent_notes, & &1.note) == ~w(earlier later)
  end

  test "a pair's page shows only the notes on releases its runs record" do
    releases =
      ExtraNotes.by_release(
        [
          note("harness", "H1", "1.0.0", "ran", ~U[2026-10-14 01:00:00.000000Z]),
          note("harness", "H1", "1.1.0", "another release", ~U[2026-10-14 01:00:00.000000Z]),
          note("wallet", "W1", "2.0.0", "ran", ~U[2026-10-14 01:00:00.000000Z]),
          # An agent's note at a version only the wallet has is about neither.
          note("harness", "H1", "2.0.0", "the wallet's version", ~U[2026-10-14 01:00:00.000000Z])
        ],
        @roster
      )

    runs = [
      %{
        harness_id: "H1",
        wallet_id: "W1",
        set_versions: %{"harness" => "1.0.0", "wallet" => "2.0.0"}
      },
      %{harness_id: "H1", wallet_id: "W1", set_versions: %{"harness" => "1.0.0", "wallet" => nil}}
    ]

    assert [{"harness", "1.0.0"}, {"wallet", "2.0.0"}] ==
             releases |> ExtraNotes.for_runs(runs) |> Enum.map(&{&1.kind, &1.version})

    assert [] == ExtraNotes.for_runs(releases, [])
  end

  defp note(kind, id, version, text, noted_at),
    do: %{kind: kind, id: id, version: version, note: text, run_url: nil, noted_at: noted_at}
end
