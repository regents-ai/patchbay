defmodule Patchbay.WalletBench.ExtraNotes do
  @moduledoc """
  Techtree's extra notes, put beside the releases they are about.

  A note is about one release: an agent or a wallet tool on the roster, at
  the version a run's set records for it. A pair's page shows the notes on
  the releases its runs record, and no others.
  """

  @type release :: %{
          kind: String.t(),
          id: String.t(),
          name: String.t(),
          version: String.t(),
          notes: [struct()]
        }

  @doc """
  The notes by release, each release with the roster's name for it and its
  notes oldest first: agents, then wallets, by name and version. Only the
  roster's agents and wallets have a name to show a note under.
  """
  @spec by_release([struct()], [struct()]) :: [release()]
  def by_release(notes, roster) do
    names = Map.new(roster, &{{&1.kind, &1.id}, &1.name})

    notes
    |> Enum.filter(&Map.has_key?(names, {&1.kind, &1.id}))
    |> Enum.group_by(&{&1.kind, &1.id, &1.version})
    |> Enum.map(fn {{kind, id, version}, notes} ->
      %{
        kind: kind,
        id: id,
        name: names[{kind, id}],
        version: version,
        notes: Enum.sort_by(notes, & &1.noted_at, DateTime)
      }
    end)
    |> Enum.sort_by(&{&1.kind, &1.name, &1.version})
  end

  @doc "Those of the releases that these runs record."
  @spec for_runs([release()], [struct()]) :: [release()]
  def for_runs(releases, runs) do
    recorded = MapSet.new(runs, &{&1.harness_id, &1.wallet_id, &1.set_versions})

    Enum.filter(releases, fn release ->
      Enum.any?(recorded, &records?(&1, release))
    end)
  end

  defp records?({id, _wallet_id, versions}, %{kind: "harness", id: id, version: version}),
    do: versions["harness"] == version

  defp records?({_harness_id, id, versions}, %{kind: "wallet", id: id, version: version}),
    do: versions["wallet"] == version

  defp records?(_recorded, _release), do: false
end
