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
  end

  def latest(runs), do: runs |> groups() |> List.first()

  def label(group) do
    run = group.latest

    "#{run.grid} · #{value(run, "harness") || "Unknown agent"} × #{value(run, "wallet") || "Unknown wallet"} · #{value(run, "model") || "Unknown model"} · runs #{Enum.map_join(group.runs, ", ", & &1.run)}"
  end

  def compare(groups, baseline_id, compared_id, checks) do
    baseline = Enum.find(groups, &(&1.id == baseline_id))
    compared = Enum.find(groups, &(&1.id == compared_id))

    if baseline && compared do
      keys =
        (@fields ++
           Map.keys(baseline.latest.versions || %{}) ++ Map.keys(compared.latest.versions || %{}))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "batch"))

      differences =
        for key <- keys,
            recorded(baseline.latest, key) != recorded(compared.latest, key),
            do: %{
              key: key,
              before: recorded(baseline.latest, key),
              after: recorded(compared.latest, key)
            }

      missing =
        Enum.filter(
          @required,
          &(is_nil(value(baseline.latest, &1)) or is_nil(value(compared.latest, &1)))
        )

      changed_versions = Enum.filter(differences, &(&1.key in ~w(harness wallet)))

      verified_wallet_upgrade? =
        match?([%{key: "wallet"}], changed_versions) and
          Enum.all?([baseline.latest, compared.latest], fn run ->
            (run.versions || %{})["wallet_verified"] == true and
              not is_nil(value(run, "wallet")) and
              value(run, "wallet") == value(run, "requested_wallet")
          end)

      changed_context =
        Enum.reject(differences, fn change ->
          change.key in ~w(harness wallet) or
            (change.key == "requested_wallet" and verified_wallet_upgrade?)
        end)

      verdict =
        cond do
          baseline.grid != compared.grid ->
            "Different tests — results are not comparable"

          baseline.id == compared.id ->
            "Choose two different version groups"

          changed_context != [] ->
            "Context changed — not an isolated version comparison"

          missing != [] ->
            "Context incomplete — comparison is descriptive only"

          length(changed_versions) != 1 ->
            "Multiple versions changed — comparison is descriptive only"

          true ->
            "Same recorded context — #{hd(changed_versions).key} version comparison"
        end

      %{
        baseline: summarize(baseline, checks),
        compared: summarize(compared, checks),
        differences: differences,
        missing: missing,
        verdict: verdict
      }
    end
  end

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
