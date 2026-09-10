# Patchbay review handoff

## Scope and state

Checkout: `/Users/sean/Documents/regent/repos/patchbay`, branch `main`, starting revision `f716239c8c4fab662e334617ba77a2de20201f92`. Original workflow-wording edits in `AGENTS.md` and `platform/README.md` are preserved. All work remains uncommitted; no push, deployment, signing or production-data changes.

The identifiable unfinished feature was historical `regent-qht.38`: shared 8px spacing, 24px container padding/radius and packaged Geist typography. `regents-ash` is absent; canonical guidance is `ash-stack` and its specialists alongside `regent-workflow`.

Astra coordinated and verified. Claude CLI Fable 5.1 implemented the shared geometry and performed independent reviews.

## Architecture

- `platform/`: Phoenix/LiveView, Ash domains for identity, forum, repair rooms and payments, backed by PostgreSQL. HTML, JSON and page-scoped WebMCP use the owning domain actions.
- `cli/`: standalone Node CLI preserving public HTTP results and opaque pagination cursors; private profile and wallet-author flows are separate.
- `contracts/`: Foundry escrow source, ABI and tests.
- Shared UI, identity, Privy and SIWA packages remain independently owned. No wallet or authorization changes were included.

## Completed changes

- Shared spacing, radius and typography adoption in `assets/css/app.css`; removed duplicate local geometry/font definitions and unused selectors. Generated shared fonts are ignored. Shared profile uses the normal shell.
- Directory-card inset now encloses screenshots and text. Receipt tear edge retains square left corners; fingerprint indicators remain unclipped glyphs.
- `Catalog.entries/0` now asks the owning enum types to match values instead of relying on already-loaded atoms. A fresh-VM invocation failed before the fix and decoded all 11 entries after it.
- Repeated catalog sync no longer rejects the same row's slug. Only the eager slug check is disabled; the SQL unique index remains. Direct isolated execution synced twice successfully and rejected a different origin claiming the same slug. No migration required.
- Empty tool-post state now carries the same `pb-tool-posts` anchor as the populated state, repairing an existing failing regression.

## Verification

- Geometry pass: **488 tests, 0 failures**. After the follow-up below, `mix precommit` (compile with warnings as errors, unused-lock check, full formatter, strict Credo, all tests): **490 tests, 0 failures**, Credo found no issues.
- JavaScript tests: 128 pass. CLI: 9 tests pass; parity: 1 test passes.
- Asset build, Ash codegen check and `git diff --check` pass. Contract check passed earlier; contract code is unchanged.
- Browser: directory, tool history, report and public agent profile at 375px and 1280px (8 checks). No document horizontal overflow. Shared Geist UI Sans/Mono loaded from packaged font URLs. Directory cards measure 24px padding/radius.
- Tool history pagination returns 30 unique fixture versions across 2 pages. Report displays all 65 fixture replies exactly once. This is below the 100-reply page boundary and does not verify reply continuation.
- Evidence is closed by default and opens on activation; focused summary has a visible outline. Live identity-provider, authenticated posting, wallet signing, paid inference and production flows were not exercised.
- No product-mirroring or smoke tests were added, following workspace instructions. Existing regression suite and disposable direct reproductions supplied verification.

## Follow-up, 2026-09-07

Claude CLI Fable 5.1 implemented the initial follow-up. At Sean's request Astra then took over directly, completed the Ash upgrade, corrected API input coercion and documentation, and ran independent verification. Logs are at `/tmp/patchbay-followup-*.log`.

1. **Dependency advisories resolved locally.** Ash 3.32.3 → 3.33.0 and Mint 1.9.3 → 1.10.0 address CVE-2026-82752 and CVE-2026-82728/82729. Related lock changes are ash_sql 0.7.1 → 0.7.3 (new string-length SQL translation) and Spitfire 0.4.0 → 0.4.1 (resolver-selected parser patch); no other locked packages changed. Patchbay requires Ash `~> 3.33` and explicitly selects `default_string_length_count: :codepoints`. Existing byte validators remain. `mix deps.get --check-locked` passes without flagged advisories. A disposable storage probe rejects oversized combining-mark tool titles/descriptions and a reply exceeding 500 bytes.

   The old frozen identity manifest required `~> 3.32.3`, excluding the fix. Its upstream working checkout already contains a compatible `~> 3.33.0` change, but that change is **uncommitted**, not part of `aa8c266`. Astra reviewed and froze those existing identity manifest/config/lock changes without modifying Regents and without `override: true`. See the exact snapshot below. Release staging requires the owning identity change to be committed and selected; local verification is not release approval.
2. **Malformed reply input resolved at both HTTP entry points.** The form validates the container and fields before writing, keeps safe text drafts, and excludes malformed values from rendering. Missing/null fields still reach normal required-field validation. Astra's independent probe found that Ash coerced boolean/numeric API notes rather than refusing them; the API now explicitly accepts only text/null fields and returns 422 `invalid` for other types. Regression coverage checks no replies are stored. The disposable edge probe passes 30 malformed form cases across normal, invalid-cursor and unreadable-cursor pages, four malformed API note cases, and signed-out refusal. Safe HTML-like draft text remains escaped.
3. **Reply admission policy, decided and resolved.** One hourly share per browser session covers both doors. `PatchbayWeb.Forum.SessionBudget` now holds the per-session advisory lock, the hourly count and the write in one transaction, and both `ForumAPI.ReportController` (reports and agent replies) and `Forum.BoardController` (human replies) go through it. Rationale: the rate key was already the browser session (`HANDOFF.md`, "It is what rate limits are counted against"); the form and the page's tools run in the same browser under the same cookie, so a limit one door counted and the other bypassed was no limit. Author kind and actor are untouched: the form still calls `add_human_reply` with the signed-in profile, the tools still call `add_reply`. Limits are unchanged (`:forum_reports_per_hour` 10, `:forum_replies_per_hour` 30) and reports/payment behaviour is unchanged. Evidence: the new controller test posts one reply through the JSON endpoint and one through the form under one session with the share set to 2, sees the third refused at both doors (form: refusal text with the draft kept; API: 429 `rate_limited`), reads exactly two stored replies (`[:agent, :human]`) and confirms another session is admitted. The disposable probe `/tmp/patchbay-followup-budget-probe.exs` ran 20 concurrent mixed human/agent writes under one session with the share at 5 outside the sandbox: 5 admitted, 15 refused, 5 stored, human rows carry the actor, all under the one session, and it deleted its rows afterwards (`/tmp/patchbay-followup-budget-probe.log`).
4. **Documentation drift, resolved.** `README.md` now lists all fourteen tools, AshPostgres 2.13, the signed-in ownership of rooms and the read-only preview, and says tool history is the one read not cut to the 16 KiB bound. `HANDOFF.md` is marked as a historical record with pointers to the current contracts; its claims are kept and corrected in place: the wallet-author API under `/api/agent`, the two later tools, the `/forum/tool-history` route and the tool-history size exception. `docs/JUDGES.md` counts fourteen tools, eight free. `llms.txt` and `cli/docs/public-api.md` were checked and needed no change. No schema or cursor was shortened.
5. **Baseline quality gates, resolved.** The three formatter files are formatted. Credo: `fit_thread_page` matches on the list shape instead of `length/1`; `:error_type` is added to the logger metadata so the thread-read warning's metadata is printed; `Board.search_terms` is split into `one_term`, `two_terms` and `host_of`; `fetch_site_ref` and `post_title` use `if`; the directory fixture's `authorize?: false` carries its justification. Nothing was suppressed. Legacy font assets, inline highlights and active-nav decoration were left alone.

## Remaining boundaries

- Release staging needs a committed identity revision containing its existing Ash 3.33 compatibility change. The reviewed local candidate works; no sibling repository was modified or committed here.
- The shared 30/hour reply cap is per browser session, not per person. Clearing cookies can obtain a fresh session; no stronger identity-based abuse guarantee is claimed.
- The paid-tool balance-readiness handoff still needs a product decision against wallet-invocation requirements; existing tests deliberately preserve that behaviour. No payment policy was changed.
- The human reply form was exercised through the router in ExUnit, not in a browser with a live sign-in. Authenticated receipt presentation was not exercised.

## Reproduction and session handles

Frozen shared dependency revisions:
- design-system: `2d64307dcccdf9e1db67c4ea5ce48acc1a40c28f`
- elixir-utils: `fbd492cf51dc5d385da86567d763f01318187bae`
- regents identity: `699850b448089e6701978f7bdd39ddd0196cbfa9`

Snapshot root: `/var/folders/r2/dyvhtvrs1wj_j0crbq99gc4r0000gn/T/patchbay-astra-deps-7oc8tgj6`.
Final verification wrapper: `sh /tmp/patchbay-followup-env.sh`; isolated test partition `astra_20260907`. It reuses `/tmp/patchbay-astra-env.sh` and selects the frozen identity candidate through `REGENT_IDENTITY_PATH`. Background commands need their own explicit environment. Do not apply browser-only fallback/worker switches to the test suite.

Identity candidate: `/var/folders/r2/dyvhtvrs1wj_j0crbq99gc4r0000gn/T/patchbay-identity-ash333-nnv6c4nt/identity`, based on `699850b448089e6701978f7bdd39ddd0196cbfa9` plus the already-existing upstream changes to `mix.exs`, `mix.lock`, and `config/config.exs`. Exact overlay SHA256s are recorded in `/tmp/patchbay-followup-identity-snapshot.json`. This candidate is a local verification input, not an immutable committed release revision.

Earlier browser instance used `http://127.0.0.1:4617`, disposable database `patchbay_testastra_browser_20260907`, fixture `/tmp/patchbay-astra-browser.exs`. Astra stopped that owned server during final verification to free database connections. Temporary inputs are not release artifacts.

Logs: `/tmp/patchbay-astra-tests-final.log`, `/tmp/patchbay-astra-js-final.log`, `/tmp/patchbay-astra-format-final.log`, `/tmp/patchbay-astra-credo-final.log`.
Follow-up logs: `/tmp/patchbay-followup-precommit.log`, `-js.log`, `-cli-check.log`, `-cli-parity.log`, `-codegen-check.log`, `-assets-build.log`, `-deps-update-mint.log`, `-deps-check-locked.log`, `-budget-probe.log`; the lockfile before the Mint update is `/tmp/patchbay-followup-mix.lock.before`.
Final Astra logs: `/tmp/patchbay-followup-astra-precommit-final.log`, `-astra-codegen-final.log`, `-astra-assets-final.log`, `-astra-js.log`, `-astra-locked.log`, `-astra-edges.log`, `-astra-budget.log`. Astra reran the mixed independent-transaction probe: 20 attempts, 5 admitted, 15 refused, exactly 5 stored, actor kinds preserved. Edge probe fixtures roll back; concurrency probe fixtures are explicitly deleted.
Browser evidence: `/Users/sean/.hermes/profiles/831/cache/browser-use/workspace/20260907_032541_2f8613/` contains `final-pages.json`, `version-pages.json`, `reply-evidence.json`, and `final-mobile-directory.png`.

Claude sessions:
- Broad read-only review: `a4b81cfe-b4ba-4148-9259-61a311c22390`
- Shared-geometry writer: `fcbed66c-a461-43fd-8c8e-c7c400fe4350`
- Independent catalog/anchor review: `a9156ace-e74e-4038-8b8f-c74d9fffaa2c`
- Independent upsert review, passing: `7d5b5fda-8f0d-4a64-9d2f-73e39e1ca09f`

Candidate worktree `/tmp/patchbay-astra-catalog` on `astra/catalog-cold-start` retains intermediate uncommitted fixes; the main checkout is the integrated result. Do not reset or prune other worktrees.
