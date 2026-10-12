defmodule Patchbay.WalletBench.Cohorts do
  @moduledoc "Exact recorded version groups and read-only comparisons of published runs."

  @fields ~w(harness wallet model reasoning_effort os judge recipe protocol access requested_wallet setup hosted_model)
  @filters ~w(harness wallet model protocol)
  @required ~w(harness wallet model reasoning_effort os judge recipe protocol access)

  def filters, do: @filters

  def value(run, key) do
    case recorded(run, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp recorded(run, "wallet") do
    versions = run.versions || %{}

    if versions["wallet_verified"] != false, do: wallet_release(versions["wallet"])
  end

  defp recorded(run, "requested_wallet") do
    requested = (run.versions || %{})["requested_wallet"]
    wallet_release(requested) || requested
  end

  defp recorded(run, key), do: (run.versions || %{})[key]

  def wallet_release?(value), do: not is_nil(wallet_release(value))

  defp wallet_release(value) when is_binary(value) do
    release =
      case value do
        "v" <> release -> release
        release -> release
      end

    if match?({:ok, _}, Version.parse(release)), do: release
  end

  defp wallet_release(_value), do: nil

  def display(nil), do: "Unknown"
  def display(value) when is_binary(value), do: value
  def display(value), do: inspect(value)

  def token(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  def options(runs) do
    Map.new(@filters, fn key ->
      values = runs |> Enum.map(&value(&1, key)) |> Enum.uniq() |> Enum.sort()
      {key, Enum.map(values, &%{id: token(&1), label: &1 || "Unknown (not recorded)"})}
    end)
  end

  def filter(runs, filters) do
    Enum.filter(runs, fn run ->
      Enum.all?(@filters, fn key ->
        selected = filters[key]
        selected in [nil, ""] or selected == token(value(run, key))
      end)
    end)
  end

  def groups(runs) do
    runs
    |> Enum.group_by(fn run ->
      # Batch identifies provenance, not a release; every other published field
      # participates so new context cannot silently mix into an old group.
      versions =
        Map.drop(run.versions || %{}, ["batch"])
        |> Map.merge(Map.new(@fields, &{&1, value(run, &1)}))

      # Missing actual releases cannot establish that two runs tested the same
      # release. Keep those attempts separate instead of pooling unknowns.
      unknown_attempt = if is_nil(value(run, "wallet")), do: run.attempt_id
      {run.grid, run.harness_id, run.wallet_id, versions, unknown_attempt}
    end)
    |> Enum.map(fn {key, runs} ->
      runs = Enum.sort_by(runs, & &1.run)
      latest = Enum.max_by(runs, & &1.finished_at, DateTime)
      %{id: token(key), runs: runs, latest: latest, grid: latest.grid}
    end)
    |> Enum.sort_by(& &1.latest.finished_at, {:desc, DateTime})
    |> named()
  end

  # Groups that read alike by test, versions and model also name the first
  # recorded field that keeps them apart, so a reader can tell them apart.
  defp named(groups) do
    Enum.map(groups, fn group ->
      alike = Enum.filter(groups, &(&1.id != group.id and headline(&1) == headline(group)))
      Map.put(group, :apart, apart(group.latest, Enum.map(alike, & &1.latest)))
    end)
  end

  defp headline(group) do
    run = group.latest

    "#{run.grid} · #{value(run, "harness") || "Unknown agent"} × #{value(run, "wallet") || "Unknown wallet"} · #{value(run, "model") || "Unknown model"}"
  end

  defp apart(_run, []), do: nil

  defp apart(run, others) do
    keys =
      (@fields -- ~w(harness wallet model)) ++
        ((Enum.flat_map([run | others], &Map.keys(&1.versions || %{})) -- ["batch" | @fields])
         |> Enum.uniq()
         |> Enum.sort())

    keys
    |> Enum.find(fn key -> Enum.any?(others, &(recorded(&1, key) != recorded(run, key))) end)
    |> apart_by(run)
  end

  defp apart_by(nil, _run), do: "a separate attempt"
  defp apart_by(key, run), do: "#{field_name(key)} #{short(recorded(run, key))}"

  defp field_name("reasoning_effort"), do: "effort"
  defp field_name("os"), do: "system"
  defp field_name(key), do: String.replace(key, "_", " ")

  defp short(nil), do: "not recorded"
  defp short(value) when is_binary(value) and byte_size(value) > 16, do: String.slice(value, 0, 8)
  defp short(value), do: display(value)

  def label(group) do
    runs = Enum.map_join(group.runs, ", ", & &1.run)
    count = if match?([_], group.runs), do: "run", else: "runs"

    Enum.join(Enum.reject([headline(group), group.apart, "#{count} #{runs}"], &is_nil/1), " · ")
  end

  def compare(groups, baseline_id, compared_id, checks) do
    baseline = Enum.find(groups, &(&1.id == baseline_id))
    compared = Enum.find(groups, &(&1.id == compared_id))
    if baseline && compared, do: comparison(baseline, compared, checks)
  end

  defp comparison(baseline, compared, checks) do
    differences = differences(baseline.latest, compared.latest)

    missing =
      Enum.filter(
        @required,
        &(is_nil(value(baseline.latest, &1)) or is_nil(value(compared.latest, &1)))
      )

    %{
      baseline: summarize(baseline, checks),
      compared: summarize(compared, checks),
      differences: differences,
      missing: missing,
      verdict: verdict(baseline, compared, differences, missing)
    }
  end

  defp differences(before, later) do
    (@fields ++ Map.keys(before.versions || %{}) ++ Map.keys(later.versions || %{}))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "batch" or recorded(before, &1) == recorded(later, &1)))
    |> Enum.map(&%{key: &1, before: recorded(before, &1), after: recorded(later, &1)})
  end

  defp verdict(%{grid: grid}, %{grid: other}, _differences, _missing) when grid != other,
    do: "Different tests — results are not comparable"

  defp verdict(%{id: id}, %{id: id}, _differences, _missing),
    do: "Choose two different version groups"

  defp verdict(baseline, compared, differences, missing) do
    {changed_versions, context} = Enum.split_with(differences, &(&1.key in ~w(harness wallet)))
    upgrade? = verified_wallet_upgrade?(changed_versions, [baseline.latest, compared.latest])
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

  # Only the wallet changed, and both runs verified they got the wallet release
  # they asked for.
  defp verified_wallet_upgrade?([%{key: "wallet"}], runs) do
    Enum.all?(runs, fn run ->
      (run.versions || %{})["wallet_verified"] == true and
        not is_nil(value(run, "wallet")) and
        value(run, "wallet") == value(run, "requested_wallet")
    end)
  end

  defp verified_wallet_upgrade?(_changed, _runs), do: false

  defp summarize(group, checks) do
    ids = MapSet.new(group.runs, & &1.attempt_id)
    checks = Enum.filter(checks, &(&1.grid == group.grid and MapSet.member?(ids, &1.attempt_id)))

    criteria =
      checks
      |> Enum.group_by(& &1.criterion_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_id, rows} ->
        %{
          name: hd(rows).criterion,
          held: Enum.count(rows, &(&1.result == "true")),
          checked: length(rows),
          runs: length(group.runs)
        }
      end)

    Map.merge(group, %{
      outcomes: Enum.frequencies_by(group.runs, & &1.outcome),
      criteria: criteria
    })
  end
end
