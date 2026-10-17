defmodule PatchbayWeb.WalletBenchRunHTML do
  @moduledoc "Escaped, read-only presentation of Techtree's versioned public run export."

  use PatchbayWeb, :html

  alias Patchbay.WalletBench.PublicRun
  import PatchbayWeb.WalletBenchHTML, only: [dot_answer: 1, dot_mark: 1]

  attr(:report, :map, required: true)
  attr(:selected_check, :string, default: nil)

  def report(assigns) do
    ~H"""
    <article id="recorded-run" class="pb-wb-report">
      <header class="pb-wb-report-head">
        <h2>Recorded run</h2>
        <p>{@report["status_label"]}</p>
        <p class="pb-wb-report-id">{@report["id"]}</p>
      </header>
      <nav class="pb-wb-report-nav" aria-label="Full result sections">
        <a :for={stage <- @report["stages"]} href={"#wb-stage-" <> stage["stage"]}>{stage["name"]}</a>
        <a href="#wb-timeline">Timeline</a>
        <a href="#versions">Compare sets</a>
        <a href={PublicRun.source_url(@report["id"])} target="_blank" rel="noopener">Source ↗</a>
      </nav>
      <dl class="pb-wb-report-facts">
        <div :for={{label, value} <- setup_facts(@report)}>
          <dt>{label}</dt><dd>{value}</dd>
        </div>
      </dl>
      <p :if={present?(@report["failure"])} class="pb-wb-report-note">{@report["failure"]}</p>
      <p :if={present?(@report["funding_refused"])} class="pb-wb-report-note">
        {@report["funding_refused"]}
      </p>

      <section
        :for={stage <- @report["stages"]}
        class="pb-wb-report-stage"
        id={"wb-stage-" <> stage["stage"]}
      >
        <header class="pb-wb-report-head">
          <h3>{stage["name"]}</h3>
          <strong>{stage["outcome_label"]}</strong>
        </header>
        <p :if={present?(stage["summary"])}>{stage["summary"]}</p>
        <p :if={present?(stage["failure"])} class="pb-wb-report-note">{stage["failure"]}</p>
        <p :if={present?(stage["plain_file"])} class="pb-wb-report-note">
          <strong>Storage finding:</strong> {stage["plain_file"]}. Passing a disclosure check does not establish secure custody or restart recovery.
        </p>
        <dl class="pb-wb-report-facts">
          <div>
            <dt>Observed duration</dt><dd>
              {with_unit(stage["timing"]["duration_seconds"], "seconds")}
            </dd>
          </div>
          <div>
            <dt>Model cost</dt><dd>{usd(stage["costs"]["model"])}</dd>
          </div>
          <div>
            <dt>Judge cost</dt><dd>{usd(stage["costs"]["judge"])}</dd>
          </div>
          <div>
            <dt>Judge model</dt><dd>{recorded(stage["judge"]["model"])}</dd>
          </div>
          <div>
            <dt>Requested wallet version</dt><dd>
              {recorded(get_in(stage, ["version", "requested"]))}
            </dd>
          </div>
          <div>
            <dt>Observed wallet version</dt><dd>
              {recorded(get_in(stage, ["version", "installed"]))}
            </dd>
          </div>
        </dl>
        <p :if={stage["criterion_count"] > 0}>
          Recorded judge answers · {stage["criterion_count"]} checks. “Unclear” and “Not recorded” do not count as “No”.
          Question wording comes from the current published rubric; the recorded prompt and judge output remain available below.
        </p>
        <p :if={stage["criterion_count"] == 0}>
          This stage is unscored and has no judgment criteria.
        </p>
        <div :if={stage["criterion_count"] > 0} class="pb-wb-report-table-wrap">
          <table class="pb-wb-report-table">
            <thead>
              <tr>
                <th scope="col">Criterion</th><th scope="col">Answer</th><th scope="col">
                  Recorded reason
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={check <- criteria(stage)}
                id={"wb-check-" <> stage["stage"] <> "-" <> check["id"]}
                class={@selected_check == check["id"] && "is-selected"}
              >
                <td><code>{check["id"]}</code> {check["criterion"]}</td>
                <td class={["pb-wb-answer", "is-" <> (check["result"] || "missing")]}>
                  <span aria-hidden="true">{dot_mark(check["result"])}</span> {dot_answer(
                    check["result"]
                  )}
                </td>
                <td>{recorded(check["reason"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <Regent.Primitives.disclosure
          id={"wb-proof-" <> stage["stage"]}
          summary="Verifier observations"
        >
          <p :if={!stage["verification"]["base"] && !stage["verification"]["money"]}>
            No independent verifier observation was recorded for this stage.
          </p>
          <div
            :for={
              {label, check} <- [
                {"Base check", stage["verification"]["base"]},
                {"Money check", stage["verification"]["money"]}
              ]
            }
            :if={check}
          >
            <h4>{label}</h4>
            <p>{recorded(check["summary"])}</p>
            <pre><code>{Jason.encode!(Map.delete(check, "summary"), pretty: true)}</code></pre>
          </div>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure id={"wb-prompt-" <> stage["stage"]} summary="Exact prompt">
          <pre><code>{recorded(stage["prompt"])}</code></pre>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure id={"wb-judge-" <> stage["stage"]} summary="Judge reasoning">
          <pre><code>{recorded(stage["judge"]["reasoning"])}</code></pre>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure
          id={"wb-timing-" <> stage["stage"]}
          summary="Timing and measurement limits"
        >
          <dl class="pb-wb-report-facts">
            <div>
              <dt>Stage started (UTC)</dt><dd>{utc(stage["timing"]["started_at"])}</dd>
            </div>
            <div>
              <dt>Stage finished (UTC)</dt><dd>{utc(stage["timing"]["finished_at"])}</dd>
            </div>
            <div>
              <dt>Current configured limit</dt><dd>
                {with_unit(stage["timing"]["limit_seconds"], "seconds")}
              </dd>
            </div>
          </dl>
          <p>
            The export labels this limit as current configuration. The historical limit is in the recorded
            <code>wall_cap_seconds</code>
            artifact when present. Queue time and judging time are separate from the stage’s observed duration.
          </p>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure
          id={"wb-evidence-" <> stage["stage"]}
          summary={"Recorded artifacts · #{length(stage["evidence"])}"}
        >
          <p>
            SHA-256 values below identify the sanitized files recorded by Techtree. Techtree checks the bytes on download. A digest establishes file integrity; it does not establish the truth of a claim.
          </p>
          <p :if={stage["evidence"] == []}>No artifact manifest was recorded.</p>
          <div :if={stage["evidence"] != []} class="pb-wb-report-table-wrap">
            <table class="pb-wb-report-table">
              <thead>
                <tr>
                  <th scope="col">Artifact</th><th scope="col">Bytes</th><th scope="col">
                    Recorded SHA-256
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={file <- stage["evidence"]}>
                  <td>
                    <a
                      href={PublicRun.artifact_url(@report["id"], stage["stage"], file["name"])}
                      target="_blank"
                      rel="noopener"
                    >{file["name"]} ↗</a>
                  </td>
                  <td>{recorded(file["bytes"])}</td>
                  <td><code class="pb-wb-artifact-hash">{recorded(file["sha256"])}</code></td>
                </tr>
              </tbody>
            </table>
          </div>
        </Regent.Primitives.disclosure>
      </section>

      <section id="wb-timeline" class="pb-wb-report-stage">
        <h3>Timeline</h3>
        <dl class="pb-wb-report-facts">
          <div>
            <dt>Started (UTC)</dt><dd>{utc(@report["started_at"])}</dd>
          </div>
          <div>
            <dt>Finished (UTC)</dt><dd>{utc(@report["finished_at"])}</dd>
          </div>
          <div>
            <dt>Total model cost</dt><dd>{total_cost(@report, "model")}</dd>
          </div>
          <div>
            <dt>Total judge cost</dt><dd>{total_cost(@report, "judge")}</dd>
          </div>
        </dl>
        <p :if={@report["timeline"] == []}>No event timeline was recorded.</p>
        <ol class="pb-wb-report-timeline">
          <li :for={event <- @report["timeline"]}>
            <time datetime={event["at"]}>{utc(event["at"])}</time>{event["label"]}
            <span :if={present?(event["failure"])}> — {event["failure"]}</span>
          </li>
        </ol>
      </section>
      <Regent.Primitives.disclosure
        :if={@report["funding"] != []}
        id="wb-funding"
        summary="Recorded funding"
      >
        <pre><code>{Jason.encode!(@report["funding"], pretty: true)}</code></pre>
      </Regent.Primitives.disclosure>
    </article>
    """
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp recorded(nil), do: "Not recorded"
  defp recorded(""), do: "Not recorded"
  defp recorded(value), do: value
  defp usd(nil), do: "Not recorded"
  defp usd(value), do: "$" <> to_string(value) <> " USD"
  defp with_unit(nil, _unit), do: "Not recorded"
  defp with_unit(value, unit), do: "#{value} #{unit}"
  defp utc(nil), do: "Not recorded"
  defp utc(value), do: value |> String.replace("T", " ") |> String.replace("Z", " UTC")

  defp total_cost(report, key) do
    complete = report["stages"] != [] and Enum.all?(report["stages"], &(&1["costs"][key] != nil))
    if complete, do: usd(report["costs"][key]), else: "Incomplete measurement"
  end

  defp setup_facts(report) do
    setup = report["setup"]

    for {label, key} <- [
          {"Agent", "harness_name"},
          {"Agent version", "harness_version"},
          {"Coding model", "model"},
          {"Reasoning effort", "reasoning_effort"},
          {"Execution environment", "os"},
          {"Test plan", "plan"},
          {"Wallet tool", "wallet_name"},
          {"Survey wallet version", "survey_wallet_version"}
        ],
        do: {label, recorded(setup[key])}
  end

  defp criteria(stage) do
    recorded = Map.new(stage["criteria"], &{&1["id"], &1})

    for number <- Enum.take(1..9, stage["criterion_count"]) do
      id = "C#{number}"

      Map.get(recorded, id, %{
        "id" => id,
        "criterion" => "Criterion not recorded for this run",
        "result" => nil,
        "reason" => nil
      })
    end
  end
end
