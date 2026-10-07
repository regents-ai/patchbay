defmodule PatchbayWeb.WalletBenchHTML do
  @moduledoc """
  The Agent Wallet Bench pages: two grids of agents by wallets, and one
  pair's runs. Every name and every outcome's meaning is Techtree's; the page
  adds only colour and layout.
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

  @doc "How many runs had an outcome, shown only when the pair ran more than once."
  def count(_count, 1), do: nil
  def count(count, runs), do: "#{count} of #{runs}"

  @doc "The square's outcomes as one sentence, for a screen reader."
  def square_label(notes, square, harness, wallet, grid) do
    said =
      case square do
        %{runs: 0, fixed: []} ->
          ["Not tested yet."]

        %{tally: tally, fixed: fixed, runs: runs} ->
          Enum.map(tally, fn {outcome, n} -> word(notes, outcome) <> ", #{n} of #{runs}." end) ++
            Enum.map(fixed, &(word(notes, &1.fixed_outcome) <> ": " <> &1.fixed_reason)) ++
            Enum.map(square_marks(square), &(String.capitalize(&1) <> "."))
      end

    Enum.join(["#{harness.name} with #{wallet.name}, #{grid_title(grid)}." | said], " ")
  end

  @doc "A square's fixed outcomes, each once: a square two fixed rows cover shows it once."
  def fixed_outcomes(square), do: square.fixed |> Enum.map(& &1.fixed_outcome) |> Enum.uniq()

  @doc "The small notes under a square's outcomes."
  def square_marks(square) do
    [
      square.second_tries > 0 && "second try ×#{square.second_tries}",
      square.signatures > 0 && "signature asked ×#{square.signatures}"
      | square.plain_files
    ]
    |> Enum.filter(& &1)
  end

  @doc "A check's result as a mark."
  def check_mark("true"), do: "✓"
  def check_mark("false"), do: "✗"
  def check_mark("open"), do: "?"

  @doc "A check's result in words, for a screen reader."
  def check_said("true"), do: "held"
  def check_said("false"), do: "did not hold"
  def check_said("open"), do: "left open"

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

  @doc "One outcome as a coloured chip, with its count when there was more than one run."
  attr(:notes, :map, required: true)
  attr(:outcome, :string, required: true)
  attr(:count, :string, default: nil)

  def chip(assigns) do
    ~H"""
    <span class={["pb-wb-chip", tone(@outcome)]}>
      {word(@notes, @outcome)}<span :if={@count} class="pb-wb-count">{@count}</span>
    </span>
    """
  end

  @doc "One square of a grid: a link to the pair, showing what its runs came to."
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
    >
      <.chip
        :for={{outcome, n} <- @square.tally}
        notes={@notes}
        outcome={outcome}
        count={count(n, @square.runs)}
      />
      <.chip :for={outcome <- fixed_outcomes(@square)} notes={@notes} outcome={outcome} />
      <span :if={@square.runs == 0 and @square.fixed == []} class="pb-wb-untested">Not tested yet</span>
      <span :for={mark <- square_marks(@square)} class="pb-wb-mark">{mark}</span>
    </a>
    """
  end
end
