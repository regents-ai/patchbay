defmodule Patchbay.WalletBench.Sets do
  @moduledoc """
  Techtree's sets, and read-only comparisons between two of them.

  A set is the runs of one agent and wallet pair on one test that share every
  recorded version and setting. Techtree decides which runs share a set, which
  set is a pair's current one, and each set's counts, cost and time. Nothing
  here regroups runs: it joins each set's runs to Techtree's summary of it and
  lays two sets side by side.
  """

  @fields ~w(harness wallet model reasoning_effort os judge recipe protocol access requested_wallet setup hosted_model)
  @filters ~w(harness wallet model protocol)
  @required ~w(harness wallet model reasoning_effort os judge recipe protocol access)

  def filters, do: @filters

  def display(nil), do: "Unknown"
  def display(value) when is_binary(value), do: value
  def display(value), do: inspect(value)

  def token(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  def options(runs) do
    Map.new(@filters, fn key ->
      values = runs |> Enum.map(& &1.set_versions[key]) |> Enum.uniq() |> Enum.sort()
      {key, Enum.map(values, &%{id: token(&1), label: &1 || "Unknown (not recorded)"})}
    end)
  end

  def filter(runs, filters) do
    Enum.filter(runs, fn run ->
      Enum.all?(@filters, fn key ->
        selected = filters[key]
        selected in [nil, ""] or selected == token(run.set_versions[key])
      end)
    end)
  end

  @doc """
  The sets these runs belong to, each with its runs in order and Techtree's
  summary of it: current sets first, then the newest.
  """
  def build(runs, summaries) do
    summaries = Map.new(summaries, &{&1.set_id, &1})

    runs
    |> Enum.group_by(& &1.set_id)
    |> Enum.map(fn {id, runs} ->
      %{
        id: id,
        grid: hd(runs).grid,
        versions: hd(runs).set_versions,
        summary: Map.fetch!(summaries, id),
        runs: Enum.sort_by(runs, & &1.run)
      }
    end)
    |> Enum.sort_by(
      &{not &1.summary.current, -DateTime.to_unix(&1.summary.last_run_at, :microsecond)}
    )
    |> named()
  end

  # A pair's sets that read alike by test, versions and model also name the
  # first recorded field that keeps them apart, so a reader can tell them apart.
  defp named(sets) do
    Enum.map(sets, fn set ->
      alike =
        Enum.filter(
          sets,
          &(&1.id != set.id and same_pair?(&1, set) and headline(&1) == headline(set))
        )

      Map.put(set, :apart, apart(set, alike))
    end)
  end

  defp same_pair?(%{summary: a}, %{summary: b}),
    do: a.harness_id == b.harness_id and a.wallet_id == b.wallet_id

  defp headline(%{grid: grid, versions: versions}) do
    "#{grid} · #{versions["harness"] || "Unknown agent"} × #{versions["wallet"] || "Unknown wallet"} · #{versions["model"] || "Unknown model"}"
  end

  defp apart(_set, []), do: nil

  defp apart(set, others) do
    keys =
      (@fields -- ~w(harness wallet model)) ++
        ((Enum.flat_map([set | others], &Map.keys(&1.versions)) -- @fields)
         |> Enum.uniq()
         |> Enum.sort())

    keys
    |> Enum.find(fn key -> Enum.any?(others, &(&1.versions[key] != set.versions[key])) end)
    |> apart_by(set)
  end

  defp apart_by(nil, _set), do: "a separate attempt"
  defp apart_by(key, set), do: "#{field_name(key)} #{short(set.versions[key])}"

  defp field_name("reasoning_effort"), do: "effort"
  defp field_name("os"), do: "system"
  defp field_name(key), do: String.replace(key, "_", " ")

  defp short(nil), do: "not recorded"
  defp short(value) when is_binary(value) and byte_size(value) > 16, do: String.slice(value, 0, 8)
  defp short(value), do: display(value)

  def label(set) do
    runs = Enum.map_join(set.runs, ", ", & &1.run)
    count = if match?([_], set.runs), do: "run", else: "runs"
    current = if set.summary.current, do: "current"

    Enum.join(
      Enum.reject([headline(set), set.apart, "#{count} #{runs}", current], &is_nil/1),
      " · "
    )
  end

  def compare(sets, baseline_id, compared_id, checks) do
    baseline = Enum.find(sets, &(&1.id == baseline_id))
    compared = Enum.find(sets, &(&1.id == compared_id))
    if baseline && compared, do: comparison(baseline, compared, checks)
  end

  defp comparison(baseline, compared, checks) do
    differences = differences(baseline.versions, compared.versions)

    missing =
      Enum.filter(@required, &(is_nil(baseline.versions[&1]) or is_nil(compared.versions[&1])))

    %{
      baseline: summarize(baseline, checks),
      compared: summarize(compared, checks),
      differences: differences,
      missing: missing,
      verdict: verdict(baseline, compared, differences, missing)
    }
  end

  defp differences(before, later) do
    (@fields ++ Map.keys(before) ++ Map.keys(later))
    |> Enum.uniq()
    |> Enum.reject(&(before[&1] == later[&1]))
    |> Enum.map(&%{key: &1, before: before[&1], after: later[&1]})
  end

  defp verdict(%{grid: grid}, %{grid: other}, _differences, _missing) when grid != other,
    do: "Different tests — results are not comparable"

  defp verdict(%{id: id}, %{id: id}, _differences, _missing),
    do: "Choose two different sets"

  defp verdict(baseline, compared, differences, missing) do
    {changed_versions, context} = Enum.split_with(differences, &(&1.key in ~w(harness wallet)))
    upgrade? = verified_wallet_upgrade?(changed_versions, [baseline.versions, compared.versions])
    changed_context = Enum.reject(context, &(&1.key == "requested_wallet" and upgrade?))

    cond do
      changed_context != [] -> "Context changed — not an isolated version comparison"
      missing != [] -> "Context incomplete — comparison is descriptive only"
      true -> versions_verdict(changed_versions)
    end
  end

  defp versions_verdict([%{key: key}]), do: "Same recorded context — #{key} version comparison"

  defp versions_verdict(_changed),
    do: "Multiple versions changed — comparison is descriptive only"

  # Only the wallet changed, and both sets verified they got the wallet release
  # they asked for.
  defp verified_wallet_upgrade?([%{key: "wallet"}], versions) do
    Enum.all?(versions, fn recorded ->
      recorded["wallet_verified"] == true and not is_nil(recorded["wallet"]) and
        recorded["wallet"] == recorded["requested_wallet"]
    end)
  end

  defp verified_wallet_upgrade?(_changed, _versions), do: false

  defp summarize(set, checks) do
    ids = MapSet.new(set.runs, & &1.attempt_id)
    checks = Enum.filter(checks, &(&1.grid == set.grid and MapSet.member?(ids, &1.attempt_id)))

    criteria =
      checks
      |> Enum.group_by(& &1.criterion_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_id, rows} ->
        %{
          name: hd(rows).criterion,
          held: Enum.count(rows, &(&1.result == "true")),
          checked: length(rows),
          runs: length(set.runs)
        }
      end)

    Map.merge(set, %{
      outcomes: Enum.frequencies_by(set.runs, & &1.outcome),
      criteria: criteria
    })
  end
end
