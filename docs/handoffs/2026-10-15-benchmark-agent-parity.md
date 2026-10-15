# Patchbay benchmark and agent-read parity — 15 October 2026

Local candidate `2612e641a9d6270e0f3ef72e2954756522f81529` (initial19093c0 plus reviewed corrections4e18a9e and2612e64), branch `pb/bench-read-parity-1015`, base `5bdea7d`.
Checkout: `/Users/sean/Documents/regent/worktrees/patchbay/wave-1012`. Not pushed or deployed. Preserve the unrelated untracked
`2026-10-14-patchbay-pickup.md`; the auth/plugin owner is working separately.

## Authority and completion

Sean’s active overnight goal in coordinator chat `01a13c47-f887-71f3-811a-beaf8fef9bf0`
asks for Patchbay WebMCP/CLI real usage and benchmark UI/forums, shared/template-first
and adversarially reviewed. Scope is bounded local implementation. The hero and
separate dependency releases are closed. This work grants no new deployment or
publication authority. No database preparation, migrations, SQL commands, public
posts, forum creation, reruns, grading changes, signing or money tests. Points stay off.

Done checklist:
- [x] Real public native WebMCP search → full existing thread read.
- [x] Compare installed CLI results and identify package/source gaps.
- [x] Map all ten approved harnesses and four wallets to existing domain forums.
- [x] Preserve exact selected test/set/filter links across HTML, Markdown and JSON.
- [x] Show dated source observations in both page formats; retain original text and grades.
- [x] Keep forum links in dialog fragments and make roster names open their boards.
- [x] Add public matrix/pair reads using the existing controller, Ash reads and comparison rules.
- [x] Verify source checks and representative rendering; execute native adapters in a labelled export preview.
- [ ] Complete configured database-backed API/browser acceptance: local published benchmark view is missing.
- [x] Independent Techtree consumer and correction reviews clear at2612e64.
- [x] Independent coordinator API review; pair filter membership/type finding corrected.
- [ ] Import/release CLI definitions through the owning shared CLI workflow.

## Implementation

`WalletBenchController` remains the common read/validation boundary. Pair validation refuses a JSON set belonging to a different test and rejects
unknown or non-string navigation filters using the matrix’s actual global options. New GET routes
`/api/wallet-bench` and `/api/wallet-bench/:harness_id/:wallet_id` use its existing actions.
`WalletBenchJSON` explicitly selects public fields, including source notes and the
existing `Sets.compare` verdict; no resource metadata or private artifacts are serialized.
The matrix supplies exact `pair_url` and copyable `read_input`, including an install
selection for a stopped wallet square. Unknown tests/filters/pairs/sets retain refusals.

`read_wallet_bench` / `read_wallet_bench_pair` register through the existing manifest
and lifecycle. Public fetches omit cookies and refuse redirects; caller cancellation
is forwarded. Invalid inputs are refused and oversized answers are refused whole
at 128 KiB. Both tools have `hosted: false`: the private plugin’s catalog is unchanged.
Manifest schemas, OpenAPI 3.1.0 and CLI source definitions agree. No shared primitive
needed changing; template public-read transport conventions were inspected and reused.

Source CLI: `regents patchbay bench matrix --test wallet` and
`regents patchbay bench pair H16 W13 --test wallet --set <id>`; optional baseline/compare
uses the website’s existing comparison. Version-filter values are opaque option tokens.
These are source definitions, not installed command support. Existing command definitions,
API operations and hosted descriptors were compared and remain unchanged.

## Actual checks and limits

| Surface | Evidence | Result |
|---|---|---|
| Live native WebMCP | Fresh tool discovery, help, search `hosted tools`, get existing thread | Same three IDs and one complete reply as CLI |
| Installed CLI | `regents` 1.10.2 public search/get and help | Reads pass; lacks `--sort` and new benchmark commands |
| Public boards | Existing pair-page mappings and fourteen ordinary board GETs | All fourteen HTTP 200; no writes |
| Local configured benchmark | Ordinary GET before new API adoption | 500, Postgrex undefined_table, wallet_bench_roster missing |
| Render/JSON | Phoenix endpoint metadata only, no Patchbay application/Repo; exported or representative maps | Selected paths, stopped/untested, absent website/source, escaped HTML, timestamps, serialization and comparison pass |
| Native benchmark adapter | Actual browser WebMCP in explicitly labelled export fixture on 4057 | Matrix→exact pair plus invalid path/test refusals pass; not database-backed acceptance |
| Phone fixture | 375px viewport, source-rendered notes/forums | Width375, no horizontal overflow; screenshot retained |
| Build | Compile warnings-as-errors, format, strict Credo, Sobelow, TS, assets, check-cli, diff check | Pass; no new product-level suite |

The fixture’s result/check layout is representative; detailed checks were not in the
export, and the preview explicitly says no database/provider is connected. It does
not substitute for actual policy/data-read acceptance. No new local DB is needed or
created. Do not repair the missing view by starting workers or applying migrations.

## Board coverage

H04 Hermes → nousresearch.com; H05 Claude → claude.com; H06 Cline → cline.bot;
H07 Kilo → kilo.ai; H08 Pi → pi.dev; H09 oh-my-pi → omp.sh; H10 Codex → openai.com;
H12 DeepSeek → deepseek.com; H13 OpenCode → opencode.ai; H16 Prime → primeintellect.ai.
W01 Bankr → bankr.bot; W03 MoonPay → moonpay.com; W07 Cast → getfoundry.sh;
W13 Zerion → zerion.io. These fourteen boards cover the approved forty pairs.
Domain normalization and ownership stay in `ProgramSites`; no one-board-per-pair table.

## Ownership and next steps

Techtree owns results, published views and historical setup/runs wording. Its completed
40 attempts/74 results must not be confused with the original three-run survey.
Historical version notes remain version-wide, with their recorded date/source added.
No old methodology copy commit was reused. TT chief `01a1214c-cddd-7023-8c4c-4ec781c76652`
has the immutable review request and its own source follow-up remains separate.

Root coordinator has exact new CLI definitions and the existing installed `--sort` gap.
The plugin owner cleared disjoint router/manifest work and retains OAuth/config/pins.
Do not bundle this candidate into that authorized auth release. Integrate its newer
reviewed main first if a later release is approved. Shared account-history projection
adoption is queued with template chief; it is not in this candidate.

Evidence: `/Users/sean/Documents/regent/artifacts/patchbay-agent-parity-1015/`:
`native-receipt.json`, `live-forum-mapping.json`, `forum-status.json`, `local-failure.json`,
representative HTML/MD/JSON outputs, render script, native preview bundle and screenshots.

## Review corrections

Root found that pair context accepted unknown or nested filters despite the new404 contract.
4e18a9e adds shared Sets.valid_filters?/2, shared pre-read type checks and global option
validation for nonempty pair context. Global options are deliberate: a fixed/empty pair
may carry a valid matrix selection recorded by another pair.2612e64 extracts that check
into a named private function, keeping strict Credo clear.

Techtree found the current-set wording wrong for historical version filters.2612e64
corrects the affected UI/MD/tool/CLI/API descriptions without changing selection. Pair
flags explicitly describe navigation context only. The retained comparison fixture now
omits batch, includes absent normalized fields and uses each record’s own timestamp;
it remains representative serialization, not exact DB provenance or upgrade acceptance.

Final consumer correction review is CLEAR at2612e641a9d6270e0f3ef72e2954756522f81529.
Receipt: artifacts/techtree-bench-reconciliation-2026-10-15/patchbay-consumer-review.md.
Root independently cleared the transport/filter correction; no release is authorized.
