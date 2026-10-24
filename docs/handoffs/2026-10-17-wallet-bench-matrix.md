# Wallet bench matrix and full report — 17 October 2026

> 24 October 2026: shipped from Patchbay main without the Techtree export below.
> Techtree had since published the same record at
> `https://techtree.sh/wallet-bench/<id>/results.json` (Techtree v188, 5bd8ae0b), so
> regents-ai/techtree#3 was closed as superseded and the full report reads that
> record. Its own field names replace the schema-1 export described here.

Sean requested an M×N matrix of square 3×3 dot grids, zoom, and full run results
inside a full-screen Patchbay modal, using the existing Techtree evidence.

## Source and delivery boundary

| Repository | Reviewed base and observed deployed code | Handoff branch |
| --- | --- | --- |
| `regents-ai/patchbay` | `6fdce7dbcaea7e0fb924d084df765f17b1b78644` | `codex/wallet-bench-matrix-20261017` |
| `regents-ai/techtree` | `119a0a4ac8f585c87c0d06809cf10f844467c1f5` | `codex/wallet-bench-export-20261017` |

Public health reads during this session confirmed those deployed revisions.
Patchbay's health is `https://patchbay.help/webmcp/health`; Techtree's is
`https://techtree.sh/healthz`. On Techtree, `deployed_source_revision` identifies
application code; `source_revision` identifies the imported catalog and is different.

This is a cloud source handoff under the Regent workflow's 16 October side-branch
exception. The Mac session tests and ships; nothing deploys from these branches.
There are no migrations, financial actions, new benchmark executions, secret-file
reads, production data writes or changes to the sign-in/Privy path in this work.
Independent review found no remaining concrete source findings after corrections;
Sentinel's release-head read remains a separate required gate.

## Result

- Real square table cells, always nine positions. Zoom 50%–250%, Fit, normal pan by
  scrolling, Control/Command-wheel zoom and sticky agent/wallet labels. At larger
  zoom, the run caption is visible. Status uses text/shape as well as color.
- Each cell shows one latest matching attempt across all matching sets. A newer
  unsuccessful install supersedes an older wallet result. Prior results remain in
  the history; `repeated_set` aggregates remain separate from displayed dots.
- Dot meanings: yes, no, unclear, not recorded, not run, not applicable. Install and
  wallet tests have nine checks. Refund, paid call and Patchbay tests have five,
  so C6–C9 are explicit padding. Unscored return has no judgment table.
- The full-screen native dialog keeps an exact shareable pair/test/set/run URL,
  optional criterion focus, Back/Forward, focus return and ordinary link behavior.
  Late responses cannot replace a newer selection. Section navigation replaces
  its history entry so Close still returns to the board.
- The report shows observed setup, stage results, storage findings, criterion
  reasons, exact public prompts, judge reasoning, independent verifier observations,
  recorded costs/durations, funding references, event history and artifact digests.
  Unavailable full evidence is a visible read error; published outcomes remain.
- HTML, Markdown, JSON schema 2, WebMCP version 2, OpenAPI and CLI descriptors share
  the new selection and filtering semantics. The tool retains its explicit 128 KiB
  intact-response refusal. No compatibility response shape is retained.

## Rigor decisions

The reference run is
https://techtree.sh/wallet-bench/b317a5d1-bfd0-4ed3-aef8-0b797f5f60bf.
It records Codex CLI 0.162.1 and MoonPay 1.100.1, with a flagged wallet pass and
plain password storage despite nine affirmative disclosure checks. The report
keeps that storage finding visible. These judge answers do not prove secure custody,
restart recovery or money actions that were not performed.

Techtree already stores per-artifact SHA-256 fingerprints over sanitized evidence.
The new export publishes those existing manifests and links to the existing
fingerprint-checked download route. A digest proves byte integrity, not the truth
of a claim. This does not repair older redacted `SHA256SUMS` file contents.

Recorded exact quantities stay decimal strings or null. Missing stage costs make
UI totals explicitly incomplete. Current configured time caps and current rubric
wording are labelled `current_catalog`, rather than represented as historical run
measurements. The original survey model descriptions are now dated as survey facts;
each new run's recorded model and version are displayed separately.

Design check: this is page composition using published Ash reads, pure Enum-based
selection, native table/dialog/history controls and Req. Existing Regent buttons and
semantic Patchbay palette tokens are reused. There is no new database resource,
background job, queue, benchmark authority or global component skin.

## Verification completed

| Check | Result and scope |
| --- | --- |
| Matrix regression suite | 13 tests, 0 failures, pure actual Sets/Matrix code; latest-attempt selection, filter ordering, newer install failure, missing states and money padding. |
| Techtree serializer boundary | 1 test, 0 failures, actual serializer/Catalog/Copy with real locked Decimal/Jason; private sentinel exclusion and exact quantity preservation. |
| Producer → consumer | Actual synthetic export round-trip passes `PublicRun.valid?/2`; mismatched IDs, criterion counts and malformed artifact names are rejected. |
| HEEx | Ten embedded sigils plus index/show/method compile to AST using locked LiveView 1.2.12 / HTML 4.3.0; relevant Elixir parses. |
| Report render | One temporary test passes with actual report/helpers and HTML escaping; nine/five/zero rows and literal script text verified. App wiring/Regent wrappers were isolated. |
| Matrix TypeScript | Targeted strict TypeScript check passes. |
| Browser logic simulation | Actual JS in a DOM simulation passes zoom clamps/Fit/wheel, labels, exact check links, single mount, request races, section history, Back/Forward/Close, errors and modified clicks. |
| Native agent tool | Mocked public execution passes exact query forwarding, malformed-input refusal before dispatch, public transport options and 128 KiB intact refusal. Existing forum tool test command exits 0. |
| CLI | `make check-cli` passes using the repository-pinned public regents-cli checker. CLI/manifest/OpenAPI parameter parity passes. |
| Source review | Independent reader confirmed producer field boundary, fixed-origin anonymous bounded fetch, escaped rendering, 9/5/0 semantics and interface parity. |
| Formatting | Changed Elixir/HEEx formatted with the locked LiveView formatter; both diffs pass whitespace checking. |

These checks used an isolated Elixir runtime and package bytes whose SHA-256 values
match the lockfiles. They do not amount to a full Phoenix/Ash build. The production
`PublicRun.fetch/1` transport, DB views, routes, CSP and real browser layout were not
exercised end to end. The browser plugin lacked an originating context and the cloud
browser could not initialize; no alternative browser was installed and no app server
was started without the site's required Privy setup.

## Mac-session acceptance and rollout

1. Read the current workspace decisions, confirm both main/live revisions, fetch the
   named handoff branches and review their exact commits. Preserve other work.
2. Run each repository's required model-free gates. In particular, run the Patchbay
   matrix test, the Techtree public export and OpenAPI tests, actual application
   compilation, assets/TypeScript and the CLI contract check. Compare failures with
   current live and give unrelated failures a named owner.
3. With the existing site-local configuration, open the Patchbay matrix on desktop
   and a narrow mobile viewport in light and dark themes. Check square geometry,
   sticky axes, zoom/Fit/pan, keyboard focus, Escape/Close/Back/Forward, criterion
   links, modifier clicks, set comparison, an unrun cell and unavailable evidence.
4. Check the supplied reference run through the new export and the full modal.
   Confirm actual versions, storage caveat, stage timing/costs, nine answers,
   verifier evidence and sanitized artifact download digests. Also inspect a
   five-check money stage and a newer failed install superseding an older pass.
   Use existing evidence only; this task does not authorize new runs or payments.
5. Sentinel reads both exact release heads. Techtree's producer goes to main and
   deploys first. Verify its public schema-1 response and malformed-ID 404. Then
   Patchbay's consumer goes to main and deploys, and both health revisions and the
   public human/agent read paths are checked again. The source-only changelog text
   must be updated to the actual release state at that step.
6. Refresh the regents-cli packaged Patchbay descriptors. Record the published CLI
   version and verify its read-only `bench pair --run ... --check ...` invocation.
   A source command description alone does not prove the installed CLI has it.

CLI lane notice to carry at release: `read_wallet_bench` / `read_wallet_bench_pair`,
`GET /api/wallet-bench` / `GET /api/wallet-bench/:harness_id/:wallet_id`;
old shape=current-set aggregates and navigation-only filters; new shape=schema 2,
latest attempt with nine explicit states plus separate `repeated_set`, exact `run`
and optional `check`, filters narrow records. Defining commit=handoff/release head;
observed live commit=`6fdce7dbcaea7e0fb924d084df765f17b1b78644`. This notice is recorded
here; no external message was sent.
