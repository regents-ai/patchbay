defmodule PatchbayWeb.WalletBenchHTML do
  @moduledoc """
  The Agent Wallet Bench pages: two grids of agents by wallets, and one
  pair's runs. Every name and every outcome's meaning is Techtree's; the page
  adds only colour and layout.

  A square shows one cell per check, each with a dot per run. Opening a square
  shows the pair's runs over the grid; the same runs are the pair's own page.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.WalletBench.Matrix

  embed_templates("wallet_bench_html/*")

  @doc "Every outcome, in legend order."
  def outcomes, do: Matrix.outcomes()

  @doc "The heading for a grid."
  def grid_title("install"), do: "Install"
  def grid_title("wallet"), do: "Make a wallet"

  @doc "The colour an outcome is drawn in."
  def tone("PASS"), do: "is-pass"
  def tone("PASS*"), do: "is-flagged"
  def tone("FAILED_TECHNICAL"), do: "is-failed"
  def tone("FAILED_SAFETY"), do: "is-unsafe"
  def tone("BLOCKED_" <> _blocker), do: "is-blocked"
  def tone("WAITING_HUMAN"), do: "is-waiting"
  def tone("INCONCLUSIVE"), do: "is-inconclusive"
  def tone("NOT_RUN"), do: "is-not-run"

  @doc "The colour of one run's dot for one check."
  def dot_tone("true"), do: "is-held"
  def dot_tone("open"), do: "is-open"
  def dot_tone("false"), do: "is-failed"
  def dot_tone(nil), do: "is-none"

  @doc "The grid's columns: wallets across the top, or agents when wallets run down the side."
  def columns(matrix, false = _wallets_down?), do: matrix.wallets
  def columns(matrix, true), do: matrix.harnesses

  @doc "The grid's rows, each with its squares' agent and wallet in column order."
  def rows(matrix, false = _wallets_down?),
    do: for(h <- matrix.harnesses, do: {h, Enum.map(matrix.wallets, &{h, &1})})

  def rows(matrix, true),
    do: for(w <- matrix.wallets, do: {w, Enum.map(matrix.harnesses, &{&1, w})})

  @doc "Techtree's short word for an outcome."
  def word(notes, outcome), do: Matrix.word(notes, outcome)

  @doc "The square as sentences, for a screen reader."
  def square_label(notes, square, harness, wallet, grid) do
    said =
      case square do
        %{runs: 0, fixed: []} ->
          ["Not tested yet."]

        %{runs: 0, fixed: fixed} ->
          Enum.map(fixed, &(word(notes, &1.fixed_outcome) <> ": " <> &1.fixed_reason))

        %{tally: tally, runs: runs, cells: cells} ->
          outcomes =
            Enum.map(tally, fn {outcome, n} -> word(notes, outcome) <> ", #{n} of #{runs}." end)

          checks =
            cells
            |> Enum.with_index(1)
            |> Enum.map(fn {cell, n} ->
              found = cell.dots |> Enum.reject(&is_nil/1) |> Enum.map_join(", ", &check_said/1)
              "Check #{n}: #{found}."
            end)

          outcomes ++ checks
      end

    Enum.join(["#{harness.name} with #{wallet.name}, #{grid_title(grid)}." | said], " ")
  end

  @doc "A square's fixed outcomes, each once: a square two fixed rows cover shows it once."
  def fixed_outcomes(square), do: square.fixed |> Enum.map(& &1.fixed_outcome) |> Enum.uniq()

  @doc "A check's result as a mark."
  def check_mark("true"), do: "✓"
  def check_mark("false"), do: "✗"
  def check_mark("open"), do: "?"

  @doc "A check's result in words, for a screen reader."
  def check_said("true"), do: "held"
  def check_said("false"), do: "did not hold"
  def check_said("open"), do: "left open"

  @doc "Whether a run took more than one step, so each step is listed."
  def steps?(run), do: match?([_, _ | _], run.turns)

  @doc "The step whose ruling is the run's result."
  def deciding_step(run), do: Enum.find(run.turns, &(&1.turn == run.decided_by))

  @doc "A plain file worth naming, or nil."
  def plain_file(value) when value in [nil, ""], do: nil
  def plain_file(value), do: value

  @doc "What a run's versions record, in a fixed order, skipping what was not recorded."
  def versions(nil), do: []

  def versions(versions) do
    for {key, label} <- [
          {"harness", "Agent"},
          {"wallet", "Wallet"},
          {"model", "Model"},
          {"reasoning_effort", "Effort"},
          {"os", "Machine"},
          {"judge", "Judge"},
          {"recipe", "Recipe"}
        ],
        value = versions[key],
        value not in [nil, ""],
        do: {label, value}
  end

  @doc "One outcome as a coloured chip."
  attr(:notes, :map, required: true)
  attr(:outcome, :string, required: true)

  def chip(assigns) do
    ~H"""
    <span class={["pb-wb-chip", tone(@outcome)]}>{word(@notes, @outcome)}</span>
    """
  end

  @doc """
  One square of a grid: a link to the pair. A tested square shows a cell for
  each check with a dot per run; any other square says why it has none.
  """
  attr(:notes, :map, required: true)
  attr(:square, :map, required: true)
  attr(:harness, :map, required: true)
  attr(:wallet, :map, required: true)
  attr(:grid, :string, required: true)

  def square(assigns) do
    ~H"""
    <a
      href={~p"/wallet-bench/#{@harness.id}/#{@wallet.id}" <> "#" <> @grid}
      class={["pb-wb-square", (@square.runs == 0 and @square.fixed == []) && "is-untested"]}
      aria-label={square_label(@notes, @square, @harness, @wallet, @grid)}
      data-wb-pair={@harness.name <> " with " <> @wallet.name}
    >
      <span :if={@square.runs > 0} class="pb-wb-cells" aria-hidden="true">
        <span :for={cell <- @square.cells} class="pb-wb-cell">
          <span :for={dot <- cell.dots} class={["pb-wb-dot", dot_tone(dot)]}></span>
        </span>
      </span>
      <.chip
        :for={outcome <- fixed_outcomes(@square)}
        :if={@square.runs == 0}
        notes={@notes}
        outcome={outcome}
      />
      <span :if={@square.runs == 0 and @square.fixed == []} class="pb-wb-untested">Not tested yet</span>
    </a>
    """
  end

  @doc "Which cell of a square is which check: the cells numbered, and the checks behind the numbers."
  attr(:id, :string, required: true)
  attr(:criteria, :list, required: true)

  def check_key(assigns) do
    ~H"""
    <div class="pb-wb-check-key">
      <span class="pb-wb-cells is-key" aria-hidden="true">
        <span :for={{_criterion, n} <- Enum.with_index(@criteria, 1)} class="pb-wb-cell">{n}</span>
      </span>
      <Regent.Primitives.disclosure id={@id} summary="The checks">
        <ol class="pb-wb-check-list">
          <li :for={criterion <- @criteria}>{criterion.criterion}</li>
        </ol>
      </Regent.Primitives.disclosure>
    </div>
    """
  end

  @doc """
  One pair's runs: versions, then for each grid its fixed reasons and its runs,
  each run with its steps when it took more than one, the checks of the step
  that decided it, and a link to the run on techtree.sh.
  """
  attr(:harness, :map, required: true)
  attr(:wallet, :map, required: true)
  attr(:notes, :map, required: true)
  attr(:grids, :list, required: true)

  def pair_detail(assigns) do
    ~H"""
    <div id="pb-wb-pair" class="pb-wb-pair">
      <section class="pb-sheet-section">
        <div class="patchbay-facts">
          <div :if={@harness.version}>
            <span>{@harness.name}</span><code>{@harness.version}</code>
          </div>
          <div :if={@wallet.version}>
            <span>{@wallet.name}</span><code>{@wallet.version}</code>
          </div>
        </div>
      </section>

      <section
        :for={grid <- @grids}
        class="pb-sheet-section pb-wb-section"
        id={grid.grid}
        aria-labelledby={grid.grid <> "-title"}
      >
        <h2 id={grid.grid <> "-title"}>{grid_title(grid.grid)}</h2>

        <p :for={fixed <- grid.fixed} class="pb-wb-fixed">
          <.chip notes={@notes} outcome={fixed.fixed_outcome} /> {fixed.fixed_reason}
        </p>
        <p :if={grid.runs == [] and grid.fixed == []} class="patchbay-muted">Not tested yet.</p>

        <ol :if={grid.runs != []} class="pb-wb-runs">
          <li :for={%{result: run, checks: checks} <- grid.runs} class="pb-wb-run">
            <div class="pb-wb-run-head">
              <h3>Run {run.run}</h3>
              <.chip notes={@notes} outcome={run.outcome} />
              <span :if={!steps?(run) && plain_file(run.plain_file)} class="pb-wb-mark">
                {run.plain_file}
              </span>
              <span class="pb-wb-when">{moment(run.finished_at)}</span>
            </div>
            <p :if={!steps?(run) && run.outcome_detail}>{run.outcome_detail}</p>
            <ol :if={steps?(run)} class="pb-wb-steps">
              <li
                :for={step <- run.turns}
                class={["pb-wb-step", step.turn == run.decided_by && "is-deciding"]}
              >
                <div class="pb-wb-run-head">
                  <h4>{step.name}</h4>
                  <.chip notes={@notes} outcome={step.outcome} />
                  <span :if={plain_file(step.plain_file)} class="pb-wb-mark">{step.plain_file}</span>
                  <span :if={step.turn == run.decided_by} class="pb-wb-mark">the result</span>
                </div>
                <p :if={step.outcome_detail}>{step.outcome_detail}</p>
              </li>
            </ol>
            <h4 :if={steps?(run)} class="pb-wb-checks-title">Checks, {deciding_step(run).name}</h4>
            <ul class="pb-wb-checks">
              <li :for={check <- checks}>
                <span class={["pb-wb-check", "is-" <> check.result]} aria-hidden="true">
                  {check_mark(check.result)}
                </span>
                <span class="visually-hidden">{check_said(check.result)}:</span>
                <span>
                  <strong>{check.criterion}</strong>
                  <span :if={check.reason} class="pb-wb-reason">{check.reason}</span>
                </span>
              </li>
            </ul>
            <Regent.Primitives.disclosure
              :if={versions(run.versions) != []}
              id={"pb-wb-versions-" <> run.attempt_id <> "-" <> grid.grid}
              summary="Versions"
            >
              <div class="patchbay-facts">
                <div :for={{label, value} <- versions(run.versions)}>
                  <span>{label}</span><code>{value}</code>
                </div>
              </div>
            </Regent.Primitives.disclosure>
            <a href={run.run_url} rel="noopener" target="_blank">This run on techtree.sh</a>
          </li>
        </ol>
      </section>
    </div>
    """
  end
end
