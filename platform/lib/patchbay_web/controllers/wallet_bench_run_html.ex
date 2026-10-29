defmodule PatchbayWeb.WalletBenchRunHTML do
  @moduledoc "Escaped, read-only presentation of a run's public results on Techtree."

  use PatchbayWeb, :html

  alias Patchbay.WalletBench.PublicRun
  import PatchbayWeb.WalletBenchHTML, only: [dot_answer: 1, dot_mark: 1]

  attr(:report, :map, required: true)
  attr(:selected_check, :string, default: nil)

  def report(assigns) do
    ~H"""
    <article id="recorded-run" class="pb-wb-report">
      <header class="pb-wb-report-head">
        <h2>The run</h2>
        <p>{@report["status"]}</p>
        <p class="pb-wb-report-id">{@report["id"]}</p>
      </header>
      <nav class="pb-wb-report-nav" aria-label="Parts of the run">
        <a :for={step <- @report["tests"]} href={"#wb-stage-" <> step["folder"]}>{step["test"]}</a>
        <a href="#wb-timeline">History</a>
        <a href="#versions">Compare sets</a>
        <a href={PublicRun.source_url(@report["id"])} target="_blank" rel="noopener">
          On Techtree ↗
        </a>
      </nav>
      <dl class="pb-wb-report-facts">
        <div :for={{label, value} <- setup_facts(@report)}>
          <dt>{label}</dt><dd>{value}</dd>
        </div>
      </dl>
      <p :if={present?(@report["failure"])} class="pb-wb-report-note">
        <.prose id="wb-failure" text={@report["failure"]} />
      </p>

      <section
        :for={step <- @report["tests"]}
        class="pb-wb-report-stage"
        id={"wb-stage-" <> step["folder"]}
      >
        <header class="pb-wb-report-head">
          <h3>{step["test"]}</h3>
          <strong>{outcome(step)}</strong>
        </header>
        <p :if={step["ruling"] && present?(step["ruling"]["summary"])}>
          <.prose id={"wb-summary-" <> step["folder"]} text={step["ruling"]["summary"]} />
        </p>
        <p :if={present?(step["failure"])} class="pb-wb-report-note">
          <.prose id={"wb-failure-" <> step["folder"]} text={step["failure"]} />
        </p>
        <p :if={present?(step["storage_finding"])} class="pb-wb-report-note">
          <strong>How the wallet keeps its key:</strong>
          <.prose id={"wb-storage-" <> step["folder"]} text={step["storage_finding"]} />.
        </p>
        <dl class="pb-wb-report-facts">
          <div>
            <dt>Time taken</dt><dd>{with_unit(step["seconds"], "seconds")}</dd>
          </div>
          <div>
            <dt>Model cost</dt><dd>{usd(step["model_cost_usd"])}</dd>
          </div>
          <div>
            <dt>Judge cost</dt><dd>{usd(step["judge_cost_usd"])}</dd>
          </div>
          <div>
            <dt>Judged by</dt><dd>{recorded(step["ruling"] && step["ruling"]["judged_by"])}</dd>
          </div>
          <div>
            <dt>Wallet version</dt><dd>{recorded(step["version_installed"])}</dd>
          </div>
          <div>
            <dt>Started</dt><dd>{utc(step["started_at"])}</dd>
          </div>
          <div>
            <dt>Finished</dt><dd>{utc(step["ended_at"])}</dd>
          </div>
        </dl>
        <p :if={checks(step) == []}>This step has no checks.</p>
        <div :if={checks(step) != []} class="pb-wb-report-table-wrap">
          <table class="pb-wb-report-table">
            <thead>
              <tr>
                <th scope="col">Check</th><th scope="col">Answer</th><th scope="col">Why</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{check, number} <- Enum.with_index(checks(step), 1)}
                id={"wb-check-" <> step["folder"] <> "-C#{number}"}
                class={@selected_check == "C#{number}" && "is-selected"}
              >
                <td>
                  <.prose
                    id={"wb-check-" <> step["folder"] <> "-C#{number}-words"}
                    text={recorded(check["check"])}
                  />
                </td>
                <td class={["pb-wb-answer", "is-" <> answer_result(check["answer"])]}>
                  <span aria-hidden="true">{dot_mark(answer_result(check["answer"]))}</span>
                  {dot_answer(answer_result(check["answer"]))}
                </td>
                <td>
                  <.prose
                    id={"wb-check-" <> step["folder"] <> "-C#{number}-why"}
                    text={recorded(check["why"])}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={present?(step["base_check"])}>
          <strong>The bench's own check:</strong>
          <.prose id={"wb-base-check-" <> step["folder"]} text={step["base_check"]} />
        </p>
        <Regent.Primitives.disclosure id={"wb-prompt-" <> step["folder"]} summary="The prompt">
          <pre><code>{recorded(step["prompt"])}</code></pre>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure
          :if={step["ruling"]}
          id={"wb-judge-" <> step["folder"]}
          summary="The judge's reasoning"
        >
          <pre><code>{recorded(step["ruling"]["reasoning"])}</code></pre>
        </Regent.Primitives.disclosure>
        <Regent.Primitives.disclosure
          id={"wb-evidence-" <> step["folder"]}
          summary={"Files · #{map_size(step["files"])}"}
        >
          <p :if={step["files"] == %{}}>No files were kept for this step.</p>
          <div :if={step["files"] != %{}} class="pb-wb-report-table-wrap">
            <table class="pb-wb-report-table">
              <thead>
                <tr>
                  <th scope="col">File</th><th scope="col">Bytes</th><th scope="col">SHA-256</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{name, file} <- Enum.sort(step["files"])}>
                  <td>
                    <a
                      href={PublicRun.file_url(@report["id"], step["folder"], name)}
                      target="_blank"
                      rel="noopener"
                    >{name} ↗</a>
                  </td>
                  <td>{file["bytes"]}</td>
                  <td><code class="pb-wb-artifact-hash">{file["sha256"]}</code></td>
                </tr>
              </tbody>
            </table>
          </div>
        </Regent.Primitives.disclosure>
      </section>

      <section id="wb-timeline" class="pb-wb-report-stage">
        <h3>History</h3>
        <dl class="pb-wb-report-facts">
          <div>
            <dt>Started</dt><dd>{utc(@report["started_at"])}</dd>
          </div>
          <div>
            <dt>Model cost</dt><dd>{usd(@report["model_cost_usd"])}</dd>
          </div>
          <div>
            <dt>Judge cost</dt><dd>{usd(@report["judge_cost_usd"])}</dd>
          </div>
        </dl>
        <p :if={@report["timeline"] == []}>No history was kept for this run.</p>
        <ol :if={@report["timeline"] != []} class="pb-wb-report-timeline">
          <li :for={event <- @report["timeline"]}>
            <time datetime={event["at"]}>{utc(event["at"])}</time>{event["label"]}
            <span :if={present?(event["failure"])}> — {event["failure"]}</span>
          </li>
        </ol>
        <h4 :if={@report["funding"] != []}>Money sent to the agent</h4>
        <ul :if={@report["funding"] != []} class="pb-wb-report-timeline">
          <li :for={payment <- @report["funding"]}>
            {recorded(payment["sent"])} · {recorded(payment["state"])}
            <code :if={present?(payment["transaction"])} class="pb-wb-artifact-hash">
              {payment["transaction"]}
            </code>
          </li>
        </ul>
      </section>
    </article>
    """
  end

  attr(:id, :string, required: true)
  attr(:text, :string, required: true)

  # A run's recorded words, with each wallet address in them drawn as one.
  defp prose(assigns) do
    ~H"""
    <PatchbayWeb.AddressText.address_text id={@id} pieces={Patchbay.AddressText.split(@text)} />
    """
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp recorded(value) when value in [nil, ""], do: "Not recorded"
  defp recorded(value), do: value
  defp usd(nil), do: "Not recorded"
  defp usd(value), do: "$" <> value
  defp with_unit(nil, _unit), do: "Not recorded"
  defp with_unit(value, unit), do: "#{value} #{unit}"
  defp utc(nil), do: "Not recorded"
  defp utc(value), do: value |> String.replace("T", " ") |> String.replace("Z", " UTC")

  defp outcome(%{"ruling" => %{"outcome" => outcome}}) when is_binary(outcome), do: outcome
  defp outcome(step), do: recorded(step["state"])

  defp checks(%{"ruling" => %{"checks" => checks}}), do: checks
  defp checks(_step), do: []

  @doc "A check's answer in Techtree's words, as the board's own dot result."
  def answer_result("Yes"), do: "true"
  def answer_result("No"), do: "false"
  def answer_result("Open"), do: "open"
  def answer_result(_answer), do: "missing"

  defp setup_facts(report) do
    machine = report["machine"] || %{}

    [
      {"Agent", recorded(report["agent"])},
      {"Agent version", recorded(machine["harness_version"])},
      {"Model", recorded(machine["model"])},
      {"Reasoning effort", recorded(machine["reasoning_effort"])},
      {"Machine", recorded(machine["os"])},
      {"Wallet", recorded(report["wallet_tool"])}
    ]
  end
end
