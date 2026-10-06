# Wallet-test matrix page: plan (6 October 2026)

Sean, 6 Oct 21:39Z: "no I mean the test matrix, nvm the head to head comment." Week item 5 is the full
AgentWalletBench test matrix on patchbay.help; the head-to-head view is dropped.

Sean, 6 Oct 22:10Z: "1 a 2 b 3 b - it will be saving it in your shared DB, so read from there".
- 2 b: build the page only once the bench run has results. Nothing is built before then.
- 3 b: the page fills in live as runs land, reading the bench's results from the shared production database
  (regents_prod), not from published files.

## The grid (Techtree chief, 6 Oct)

The bench is rebuilt on Harbor and owned by the Techtree chief. 9 agents × 12 wallets = 108 squares, one grid per
test (install, make a wallet).

- Agents: Hermes H04, Claude Code H05, Cline H06, Kilo H07, Pi H08, oh-my-pi H09, Codex H10, DeepSeek H12,
  OpenCode H13.
- Wallets: Bankr W01, MetaMask W02, MoonPay W03, Coinbase Agentic Wallet W05, Phantom W06, Foundry Cast W07,
  Circle W09, Safe CLI W10, Zerion W13, Splits W14, Privy W15, Turnkey W17.
- Squares that never run keep their own outcome and are never drawn as failures: MetaMask, Turnkey, Splits, Privy,
  Phantom and Circle wait on a person; Coinbase cannot run on a server; Safe makes no keys; Cline gets the install
  test only, so its wallet test is not run.

## What the page shows

- Address: patchbay.help/wallet-bench, linked from the survey post.
- Agents down the side, wallets across the top, a button that swaps them.
- Each square: its result in words and colour, with a legend; a count where a pair ran more than once ("2 of 3"),
  PASS and PASS* counted separately, never one pass or fail made from several runs. An empty square means
  "not tested yet", never zero.
- Tapping a square opens that pair: each run's result and reason, the five checks, and a link to the run's page
  on techtree.sh (run_url).
- The setup every run shares (model, stock agents, one machine per agent) above the grids, and a note on how many
  of the 108 squares have results so far.
- On a phone the grid scrolls sideways inside its own box; the page itself never does. Works without JavaScript.
- The published v7 survey stays on its blog post; this page shows the new bench only.

## Data

- Read straight from regents_prod. Draft agreed with the Techtree chief (6 Oct, final names after the pilot):
  read-only views in techtree_app, owned and changed only by Techtree. Patchbay keeps no names, rules or wording.
  - wallet_bench_results: one row per (harness, wallet, grid, run), grid = install | wallet, already folded by
    Techtree: outcome (PASS, PASS*, WAITING_HUMAN, INCONCLUSIVE, FAILED_TECHNICAL, FAILED_SAFETY), outcome_detail
    (judge's one-line summary or the stop reason), plain_file, second_try (install came from the second try),
    signature_asked (wallet result needed the signature request), attempt_id, run_url
    (https://techtree.sh/wallet-bench/{attempt_id}), versions, finished_at. Retries are new runs; rows are only
    added and final once they appear.
  - wallet_bench_checks: one row per check (C1–C5): harness_id, wallet_id, grid, run, attempt_id, criterion_id,
    criterion, result (true | false | open).
  - wallet_bench_fixed: cells that never run, keyed by harness_id | "*", wallet_id | "*", grid | "*" →
    fixed_outcome, fixed_reason (e.g. Cline's wallet grid → NOT_RUN).
  - wallet_bench_roster: kind (harness | wallet), id, name, version.
  - wallet_bench_notes: key → plain text, for each outcome's meaning and the shared setup.
  Patchbay's database login gets SELECT on those views only, so Patchbay never depends on the bench's own tables.
  The grant is a production change the Techtree chief puts to Sean with the bench release; Patchbay does not
  grant it.
- Two grids (install, make a wallet). An install square notes a second try; a wallet square notes when the
  signature request was needed and names the plain file behind a PASS*.
- The page queries the views when it is opened, so a finished run shows on the next visit; no copy in Patchbay's
  tables and nothing to schedule.
- Waiting on: the view names and the grant (Techtree chief, after the pilot), then results from the run.

## Checks before release

- Every row in the view lands in exactly one square; square counts add up to the view's row counts.
- All 108 squares are accounted for; each outcome kind has its own word and colour; nothing untested reads as a
  failure.
- Keyboard and screen reader reach every square; phone width has no sideways page scroll.
