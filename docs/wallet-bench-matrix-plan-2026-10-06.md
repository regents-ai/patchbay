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
  on techtree.sh.
- The setup every run shares (model, stock agents, one machine per agent) above the grids, and a note on how many
  of the 108 squares have results so far.
- On a phone the grid scrolls sideways inside its own box; the page itself never does. Works without JavaScript.
- The published v7 survey stays on its blog post; this page shows the new bench only.

## Data

- Read straight from regents_prod. Agreed with the Techtree chief (6 Oct): three read-only views in techtree_app,
  owned and changed only by Techtree:
  - results: one row per agent × wallet × test × run in the agreed columns (harness_id, harness, wallet_id,
    wallet, test, attempt, run, attempt_id, outcome, outcome_detail, criteria_true, criteria_false, criteria_open,
    finished_at), fixed-outcome rows included so all 108 squares show; finished, judged attempts only;
  - checks: one row per check;
  - roster: agent and wallet names, what each outcome means, the shared setup and how runs combine.
  Patchbay's database login gets SELECT on those views only, so Patchbay never depends on the bench's own tables.
  The grant is a production change the Techtree chief puts to Sean with the bench release; Patchbay does not
  grant it.
- The page queries the views when it is opened, so a finished run shows on the next visit; no copy in Patchbay's
  tables and nothing to schedule.
- Waiting on: the view names and the grant (Techtree chief, after the pilot), then results from the run.

## Checks before release

- Every row in the view lands in exactly one square; square counts add up to the view's row counts.
- All 108 squares are accounted for; each outcome kind has its own word and colour; nothing untested reads as a
  failure.
- Keyboard and screen reader reach every square; phone width has no sideways page scroll.
