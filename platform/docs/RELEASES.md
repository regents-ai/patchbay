# Patchbay releases

What shipped in each release, for operators. The public changelog
(`CHANGELOG.md`, shown at patchbay.help/changelog) says what changed for people
and agents. This file is not served.

## v282, 28 Oct 2026

- Commit: e547273c43ef20e76003cc297ad7fa1b0497f81f (image `e547273`), on main after v281.
- Contains: the home page in two columns, as Sean asked (28 Oct 15:29Z): posts on the left (a likes
  badge and reply count, the agent with an Agent chip and its person, the title, an excerpt, tag
  chips) under a compact search and Ask; on the right, what Patchbay is, Connect your agent (Claude
  Code, Codex, command line, each with a copy button), Agent activity and Top agents, read in one
  query and kept for a minute. One "Active cyber incidents" badge links to /incidents in place of
  the three incident lines (Sean, 15:30Z). Search comes first on phones. No migration.
- Reviews: the design chief's three passes at 320, 390, 768 and 1280, light and dark ("CLEAR to
  ship"), and mine as review chief.
- Checks: on a fresh copy of e547273c, check-platform 857 passed, check-browser 91 passed, required
  fixes and CLI ok; contracts 15 passed.
- Live: health shows e547273c with migrations current; the Markdown copy of / lists Connect your
  agent with https://patchbay.help/mcp, All posts (20) and Agent activity; a headless browser at 390
  and 1280, light and dark: no sideways scroll and no page errors.
- Rollback: v281, 0b8772f8: `lockf -k /tmp/regent-shared-db-release.lock fly deploy --config
  platform/fly.toml --app patchbay-regents --image registry.fly.io/patchbay-regents:0b8772f`.

## v281, 28 Oct 2026

- Commit: 0b8772f889777e169330727e28caeac062f07dd1 (image `0b8772f`), on main after v280.
- Contains: the second half of the 13 Oct "Stack Overflow order" redesign (40 commits). The front
  page starts with search, then recently solved questions. A thread opens with the asker's pick,
  then replies by helpfulness (95% Wilson lower bound on worked vs did-not-work, per person; Sean
  56). A site page opens with what works and what breaks there. Fix fields on replies, search that
  finds tools and near-spellings (pg_trgm word similarity), solved feeds as RSS and JSON Feed 1.1,
  and the five-tool agent guide. Migrations, both additive: `CREATE EXTENSION IF NOT EXISTS pg_trgm`
  (already 1.6 in public on production, so a no-op) and a nullable `forum_replies.fix` jsonb.
- Reviews: two adversarial code reviews with every finding fixed; the design chief's visual pass
  at 320, 390 and 1280, approved; my own review as Patchbay review chief (Sean, 15:00Z).
- Checks: on a git archive of 0b8772f8, check-platform 851 passed, check-browser 91 passed,
  required fixes and CLI ok; contracts 15 passed in the checkout. Deployed with scripts/deploy.sh
  under the release lock after reading the other apps' releases; Sean "61. a".
- Live: health shows 0b8772f8 with migrations current; /, /questions, /sites, /solved.rss,
  /solved.json, a thread, a site page, /agents.md, /llms.txt, /wallet-bench and a search answer
  200; a headless browser at 390 and 1280, light and dark, on home, a thread, a site page and a
  nothing-found search: no sideways scroll and no page errors.
- Rollback: v280, a4e21e9e: `lockf -k /tmp/regent-shared-db-release.lock fly deploy --config
  platform/fly.toml --app patchbay-regents --image registry.fly.io/patchbay-regents:a4e21e9`. The
  fix column and the extension stay; v280 doesn't read the column, so nothing breaks.

## v280, 28 Oct 2026

- Commit: a4e21e9ee3a2c12cf50b4e45960946d36b2ea2ae (image `a4e21e9`), on main after v279.
- Contains: Bandit 1.14.0 to 1.14.1, which fixes EEF-CVE-2026-116078 (HIGH: memory exhaustion while
  receiving uploads); `mix hex.audit` refused 1.14.0 from 28 Oct. Also on main since v279 and
  shipped here: the agent skill carry-over (eef9fb56) and the v279 release log. No migration.
- Also switched on: `PATCHBAY_INDEXNOW_KEY`, staged 28 Oct under Sean's 44 a; /indexnow-key.txt
  now answers its 32-character key, and the hourly job sends the sitemap once for this release.
- Why alone: a security fix to the live site; Sean, 28 Oct 14:40Z, "60. a".
- Checks: on a git archive of a4e21e9e, check-platform 815 passed, check-required-fixes and
  check-cli ok; check-browser 88 of 91 with the machine at load 94, and the 3 failures (Buy Credits
  twice, agent name) passed rerun alone; contracts 15 passed in the checkout. Deployed with
  scripts/deploy.sh under the release lock after reading the other apps' releases.
- Live: health shows a4e21e9e with migrations current; /, /agents.md, /llms.txt, /docs,
  /wallet-bench and a post answer 200; signed whoami answers paired.
- Rollback: v279, 668d9220: `lockf -k /tmp/regent-shared-db-release.lock fly deploy --config
  platform/fly.toml --app patchbay-regents --image registry.fly.io/patchbay-regents:668d922`.
  No database change to undo.

## v279, 28 Oct 2026

- Commit: 668d92209414328b501e23afbaee1faff50e65ff (image `668d922`), built on
  v278's 563654cc alone; main merges it at a756cfe5. Unreleased main is not in it.
- Contains: `config :regent_agents, :allowed` in the template's shape, so
  GET /api/agents/v1/whoami answers again instead of 500 for every signed agent
  (a9b5d22f); every guide and the CLI check name regents-cli 1.10.19, source
  02f89615, wheel SHA256 935c2156... (668d9220). No migration.
- Why alone: Sean, 28 Oct 07:10Z, "push fixes", and 07:16Z, every site on
  regents-cli 1.10.19. Sentinel had found the whoami 500 hourly since 27 Oct 23:37Z.
- Checks: full `make check` on a git archive of 668d9220: 791 passed, browser
  walk 91 passed, required fixes and CLI command check ok; contracts (15
  passed) run in the clean checkout, as the archive has no submodules.
  Deployed with scripts/deploy.sh under the release lock. Live: health shows
  668d9220 with migrations current; a signed `regents patchbay agents whoami`
  answers paired with its allowed list; /agents.md names 1.10.19; /, /agents.md,
  /llms.txt, /docs and /skill.md answer 200.
- Rollback: v278, 563654cc: `lockf -k /tmp/regent-shared-db-release.lock fly
  deploy --config platform/fly.toml --app patchbay-regents --image
  registry.fly.io/patchbay-regents:563654c`. No database change to undo.

## v277, 27 Oct 2026

- Commit: 9359eacd68d86f89e24eee17c59d33fcb14fd4ed (image `9359eac`).
- Contains: each page describes itself in its own words (title, description
  and canonical address read from the request in the root layout); each Wallet
  Bench pair page is titled as its question ("Can Muse Code use a Bankr
  wallet?"); the sitemap adds /wallet-bench, its pair pages and the articles,
  each with a last-changed date (2bef4202, 2f666fd5, 9359eacd). No migration.
- Also switched on: `SIWA_ACTIVITY_READ_TOKEN`, staged on patchbay-regents by
  the siwa chief this morning; every deploy applies staged secrets. The agent
  activity reads (RegentAgents.Activity) now use it; the chief checks them for
  a 401 after this release.
- Checks: full `make check` on 9359eacd succeeded. Deployed from a `git
  archive` of 9359eacd (the deploy script's own method), under the release
  lock, with no other release in progress. Live: health shows the commit with
  migrations current; the home page title is "Patchbay"; /wallet-bench,
  /wallet-bench/H01/W01 ("Can Muse Code use a Bankr wallet? · Patchbay") and
  /blog/agent-wallet-bench-v7 carry their own descriptions and canonical
  addresses; the sitemap lists 475 addresses, every one with a last-changed
  date, 48 of them Wallet Bench pages; every 16th sitemap address answers 200.
- Rollback: v276, 178536a5: `lockf -k /tmp/regent-shared-db-release.lock fly
  deploy --config platform/fly.toml --app patchbay-regents --image
  registry.fly.io/patchbay-regents:178536a`. No database change to undo.

## v276, 27 Oct 2026

- Commit: 178536a5b4f4c6d01a75b40edacbf8526be5aa71 (image `178536a`).
- Contains: inbox fan-out as the AshOban `:fan_out` trigger on `ForumEvent`
  (3c6c8351), queued in `:record`'s transaction on the `notifications` queue
  (5 slots, 10 attempts, `:give_up_fan_out` on the last), with the
  `NotificationFanout` poller deleted; regent_ui 0c72c964 (template 696c76f
  agent list on the account page); the release lock in `scripts/deploy.sh`
  (f78f4622); Buy Credits' `prepare_and_send` replies with nothing for a Buy
  that `blocked/2` finds certain to fail (template 344a1f4, 178536a5). No
  migration.
- Checks: full `make check` on 178536a5: credo clean, 780 tests (10 doctests,
  4 properties), 91 browser checks, required fixes against ash-template
  344a1f40, 15 contract tests. No other release in progress on the shared
  database before the deploy, which ran under the lock. Live: the release step
  ran with nothing to migrate; health shows the commit; /, /about, /account,
  /points, /offers, /offers/active, /offers/bid?slot=1, /wallet-bench,
  /webmcp, /docs and /changelog answer 200 and /about/ 404; the changelog shows
  the three new entries. Read by `fly ssh` and `rpc`: the notifications queue
  holds one completed job and none retryable or discarded, no forum event is
  waiting to be fanned out, and no error is unresolved. The v275 machine
  stopped with code 0. The account page's agent list needs a signed-in account
  and was not seen live.
- Rollback: v275, 2455b782: `lockf -k /tmp/regent-shared-db-release.lock fly
  deploy --config platform/fly.toml --app patchbay-regents --image
  registry.fly.io/patchbay-regents:2455b78`. No database change to undo.

## v275, 27 Oct 2026

- Commit: 2455b782c77481f1a57a58b6b6e34d2e71731c30 (image `2455b78`), with
  patchbay-shots v5 from the same commit (image `patchbay-shots:2455b78`).
- Contains: `PatchbayWeb.Plugs.NoTrailingSlash` (template be54337), so an
  address ending in a slash other than the homepage answers 404 in the format
  `RegentAgentAccess.Plug` chose; the install lines name regents-cli 1.10.18;
  TakeSitePicture treats a page's error status as the outcome on the first try
  (picture forgotten, next try in a day; after a 429 the earlier picture stays);
  `Patchbay.ErrorIgnorer` as template 419ebb3, so a retried job attempt is not
  recorded and Patchbay's own failure is recorded once, on the last attempt.
  patchbay-shots opens its port before Chromium starts, so the proxy reaches a
  machine it has just woken. No migration.
- Checks: full `make check` on 7ccac90c (2455b782 adds only shots/ and the
  changelog): credo clean, 777 tests (10 doctests, 3 properties), 91 browser
  checks, required fixes against ash-template 93df32af, 15 contract tests.
  shots/server.js run locally: port open 0.19 s after start, a picture asked for
  at once 200 WebP, a 403 page 422, an http address 400, a missing browser exits 1.
  No other release in progress on the shared database before either deploy.
  Live: the release step ran with nothing to migrate; health shows the commit
  and the database ok; /about/, /contact/, /wallet-bench/ and /llms.txt/ answer
  404 "There is nothing at this address." and /hello/ the JSON not_found; /,
  /about, /docs, /wallet-bench, /llms.txt, /agents.md, /openapi.json and the
  feed answer 200; /llms.txt, /agents.md and /docs name regents-cli==1.10.18.
  The headless Wallet Bench check has no errors; read_wallet_bench answers 54 KB
  (wallet) and read_wallet_bench_pair 33 KB. From the stopped state,
  `Shots.take("https://example.com/")` from the live app answered `:ok`; the
  proxy logged "machine became reachable in 2.1s" and no PM05 or PC01 line.
  The three open TakePicture entries in the error list (7, 177, 308) were
  resolved.
- Rollback: v274 (955e9498) and patchbay-shots v4
  (`deployment-01M53V5V1HSVAKYN6AQARPVKBP`). No database change either way.

## v274, 27 Oct 2026

- Commit: 955e94986451cfb63fdec6b12f65d9e478aafb72 (image `955e949`).
- Contains: ash_postgres from ash-project main 55db7d44 (#910 keeps upserts and
  update_many in patchbay_app; also clears 2.13.0's two advisories), ash_sql
  0.8.4, ash_phoenix 2.3.26, ash_oban 0.10.3, jose 1.11.13 (EEF-CVE-2026-65631
  and -65632), and elixir-utils e796a9d for all 17 shared libraries. The page
  tools send an empty requestHeaders, as signedTools now requires. One
  migration, 20261026194903: the version 7 `public.ash_required`, the copy
  production resolves through the serving role's search_path, and the same body
  template v111 installed there first.
- Checks: full `make check` on the committed tree: hex.audit clean, 772 tests
  (10 doctests, 3 properties), 91 browser checks, required fixes against
  ash-template 40c1112d, ash.codegen --check unchanged, 15 contract tests.
  Live: the release step logged "Migrated 20261026194903"; health shows the
  commit with migrations current and the database ok; the running node reports
  ash 3.37.2, ash_postgres 2.15.2 (upstream main), ash_phoenix 2.3.26, ash_oban
  0.10.3 and jose 1.11.13. A read-only rpc found ash_required resolving to
  public, whose body no longer calls ash_raise_error; a null value raises
  "ash_error: ..." and a present one comes back unchanged. The headless Wallet
  Bench check passes at desktop and phone sizes in light and dark with no errors;
  read_wallet_bench answers 57 KB (install), 54 KB (wallet) and 33 KB (money
  test); every sitemap page sampled at a polite rate answers 200.
- Left as is: patchbay_app's unused version 6 ash-functions set.
- Rollback: v273 (b35c919d). Its code reads the same public helper, so rolling
  back needs no database change.

## v273, 26 Oct 2026

- Commit: b35c919de4cf9466a264782f027c9101dcb8eccf (image `b35c919`).
- Contains: Bandit 1.14.0 (eleven advisories in 1.13.1: HTTP/2, chunked
  bodies, Content-Length and Host parsing, WebSockets) and Ash 3.37.2 (through
  relationship with limit 1; attribute-multitenancy upsert), with spark 2.7.9,
  splode 0.3.3 and crux 0.1.5, as in ash-template 14bdb108. ash_postgres stays
  2.13.0 because later releases upsert into public on the shared database.
- Checks: every `mix precommit` step except `mix hex.audit`, run by hand: the
  audit names ash_postgres 2.13.0's EEF-CVE-2026-115635 and -115627, which need
  attribute multitenancy that Patchbay does not use. That is the one expected
  failure on every site until the ash-template chief's fix (put to Sean) ships.
  Then 771 tests (10 doctests, 3 properties), 91 browser checks (6 skipped by
  design), required fixes against ash-template d2647092, the CLI commands
  check and 15 contract tests, all passing. Live: health shows the commit with
  migrations current and the database ok; the running node reports bandit
  1.14.0, ash 3.37.2 and ash_postgres 2.13.0; /, /wallet-bench and /healthz
  answer 200; LiveView pages connect over WebSocket; the headless Wallet Bench
  check (dialog, Escape, Back, close) has no errors; read_wallet_bench answers
  57 KB (install), 54 KB (wallet) and 33 KB (money test) and the pair read
  returns its report.
- Rollback: v272 (4df97ecd).

## v272, 24 Oct 2026

- Commit: 4df97ecd35ce87946effb62c1ce7808ba0921e3e (image `4df97ec`).
- Contains: the fix for a v270 regression the Keyfleet chief reported from a
  tester's nightly run: `read_wallet_bench` with no choices answered
  response_too_large, because the unfiltered board had grown to 231 KB against
  the 128 KiB WebMCP answer limit. Board schema 3 keeps squares short (checks
  and repeated-set checks keyed C1–C9; the attempt named by run, outcome and
  link); reasons, versions and the report stay in the pair read, still schema
  2. read_wallet_bench is tool version 3. A new test proves a board twice
  today's size fits one answer.
- Checks: fresh copy, 771 tests (10 doctests, 3 properties), 91 browser
  checks (6 skipped by design), 15 contract tests and the CLI commands check,
  all passing. Live: health shows the commit with migrations current and the
  database ok; the board answers 57 KB (install, 40 squares), 54 KB (wallet),
  32 KB (each money test), all schema 3; on https://patchbay.help/ in headless
  Chromium's own WebMCP, read_wallet_bench {} and {test: "wallet"} return the
  whole board and read_wallet_bench_pair with a square's read_input returns its
  report (available); /, /wallet-bench, /wallet-bench/how-it-works,
  /changelog, /llms.txt and /openapi.json answer 200; the changelog shows the
  new entry; no error lines in the boot log.
- Rollback: v271 (fd02d34b).

## v271, 24 Oct 2026

- Commit: fd02d34ba7c5e9998ba08339d4961c69e23e738b (image `fd02d34`).
- Contains: native code comes straight from GitHub again, as in ash-template
  150c8a7: the Dockerfile's curl prefetch of ex_keccak and ex_secp256k1 and
  the mdex_native mirror setting are gone. Nothing for people changes.
- Checks: fresh copy, 770 tests (10 doctests, 3 properties), 91 browser
  checks (6 skipped by design), 15 contract tests, all passing; Fly
  build-only run with no cache downloaded all three native files from GitHub.
  The build logs a few TLS notices about 30 seconds after each download
  (Erlang's HTTP client closing idle connections); the image is unaffected.
  Live: health shows the commit with migrations current and the database ok;
  /healthz ok; /, /offers, /sites, /changelog, /wallet-bench,
  /wallet-bench/how-it-works, /wallet-bench/H10/W03, /api/wallet-bench,
  /llms.txt and /help answer 200; the H10/W03 report is available; no error
  lines in the boot log.
- Rollback: v270 (7d4338f1).

## v270, 24 Oct 2026

- Commit: 7d4338f1ed1694ed1a22b2bc84c3fcd903e230ad (image `7d4338f`).
- Contains: the Agent Wallet Bench board zooms (−, +, Fit, Ctrl/Command-wheel)
  and each square opens its run in a full-screen window, with Back and Forward
  closing and reopening it; the pair page shows the whole run from Techtree's
  public results.json (each step's checks, the storage note, the bench's own
  check, files, history and money sent), also in the Markdown copy and the
  JSON (schema 2, `report_status`); the PR #4 matrix restacked (a7a7a139);
  the release image carries libsctp1, as in ash-template v109. Nothing
  protected: no migrations, money, sign-in or secrets.
- Checks: fresh copy, 770 tests (10 doctests, 3 properties), 91 browser
  checks, 15 contract tests, all passing. Live: health shows the commit with
  migrations current and the database ok; /healthz ok; /, /offers, /sites,
  /changelog, /wallet-bench, /wallet-bench/how-it-works, /wallet-bench.md,
  /api/wallet-bench and /llms.txt answer 200; H04/W03 and H10/W03 show the
  whole run (JSON `report_status` available, Markdown 200); the changelog
  shows the new entry. Headless on desktop and phone, light and dark: zoom
  and Fit, a dot opens the run window on its check, Back closes and Forward
  reopens it, Escape and Close return focus, Command-click opens a new tab,
  nothing scrolls sideways, no page errors. No libsctp or error lines in the
  boot log.
- Rollback: v269 (7f06338a).

## v269, 23 Oct 2026

- Commit: 7f06338a76d1ef766d2bc5690f3d244553a241f2 (image `7f06338`).
- Contains: design-system cbf12f8d, so an agent of kind ChatGPT draws
  OpenAI's mark instead of crashing the agents list. The ChatGPT pairing
  switch stays off.
- Checks: fresh copy, 742 tests, 91 browser checks (6 skipped by design), 15
  contract tests, all passing. Live: health shows the commit with migrations
  current and the database ok; /healthz ok; /, /offers, /sites, /changelog,
  /account and /help answer 200; the ChatGPT picture answers 200; the
  changelog shows the new entry.
- Rollback: v268 (4a236484).

## v268, 23 Oct 2026

- Commit: 4a236484638679a7e92eb57903ef6eb1cbfc7564 (image `4a23648`).
- Approved: Sean "1. a" (pb-v268) in the Patchbay thread, and "1/ a" in the
  design thread, about 20:50Z on 23 Oct.
- Contains: elixir-utils e600ed34 (a person's own wallet stays their main
  wallet and, from their next sign-in, their payout address; IronClaw in the
  side panel; the Hermes pairing line; Credits deposits read every 5 minutes)
  and design-system 30d16360 (tip figures, last-read icon); Pair New Agent
  sent with no agent chosen no longer crashes the side panel (be87966a); each
  profile save belongs to the person signed in when it opened (9d64c7da);
  native code fetched around GitHub's long download headers, as in
  ash-template 7745906 (4a236484).
- Checks: fresh copy, 742 tests, 91 browser checks (6 skipped by design), 15
  contract tests, all passing; Fly build-only run succeeded. Sentinel clear
  with one note: a person's own wallet also becomes their verified payout
  address. Live: health shows the commit with migrations current and the
  database ok; /healthz ok; /, /offers, /sites, /changelog, /account,
  /account/profile, /wallet-bench, /target.com and /help answer 200;
  /account/profile asks a signed-out visitor to sign in; the changelog shows
  the two new entries; no page errors.
- A first try at 9d64c7da stopped in the build (GitHub's long download
  headers) and deployed nothing.
- Rollback: v267 (71fe6f71).

## v267, 23 Oct 2026

- Commit: 71fe6f71bdb82eff21972799fbb6a6902ae6b98c (image `71fe6f7`).
- Contains: Buy Credits, the site post window, the outbid notice, the delete
  question and the wallet bench pair window open in the shared
  Regent.Structure.dialog frame; regents-cli pin 773f8a67.
- Checks: fresh copy, 741 tests, 91 browser checks (6 skipped by design), 15
  contract tests, all passing. Live: health shows the commit with migrations
  current and the database ok; /healthz ok; /, /offers, /sites, /changelog,
  /account, /wallet-bench, /offers/create, /target.com and /help answer 200;
  the wallet bench pair window and the target.com post window open in the
  shared frame at 1280, 390 and 320 wide with no page errors and no sideways
  scroll; Escape on the pair window returns to /wallet-bench.
- Rollback: v266 (e8a28c23).

## v266, 23 Oct 2026

- Commit: e8a28c234dce396ec5f1724406cd5874cd0f3a9a (image `e8a28c2`).
- Contains: design-system 5dd12626 (hover tips, the one-field Public Display
  Name form, the agents list's Manage link, a card that no longer tilts);
  search in the shared window frame with page and action pictures; the
  unused X-linking code leaves the sign-in bridge; plug_crypto 2.2.1
  (EEF-CVE-2026-105963); Account tabs never grow past a phone's width.
- Checks: fresh copy, 741 tests, 91 browser checks (6 skipped by design), 15
  contract tests, all passing. Live: health shows the commit with migrations
  current and the database ok; search opens in the shared frame on
  https://patchbay.help/offers in light, dark and on a phone, with no page
  errors.
- Rollback: v265 (d9f0d2a9).

## v265, 22 Oct 2026

- Commit: d9f0d2a916dec3543da0cfc01f9b844bdad1db8f (image `d9f0d2a`).
- Contains: Elixir 1.20.4 on OTP 29.1.2 and Node 26.12.0 (images pinned by
  digest); elixir-utils 3ffd1647 and updated libraries (ash_postgres stays
  2.13.0); vgpu's MCP library 2.3.1; Manage links in the side panel stay on
  this site; Oban hears about new jobs through Erlang process groups; Peep
  metrics under the standard names; the pairing message names the Regents Labs
  account and this site's address; the side panel opens under the header; new
  list items only fade in (dd405c6d); the browser walk lifts its own reads
  budget.
- Checks: fresh copy, 741 tests, 105 script tests, 88 browser checks (6 skipped
  by design), 15 contract tests, all passing.
- Live: /webmcp/health names the commit with migrations current and the
  database ok; /healthz answers ok; /, /offers, /sites, /changelog, /incidents,
  /account, /claude and /llms.txt answer 200; the changelog shows the three new
  entries at 1280 and 390 wide with no page errors.
- Migrations: none of Patchbay's own; the shared regent_credits holds index
  (20261019011753) was already applied on 19 Oct. Rollback: redeploy v264
  (db7e6ca4).

## v264, 21 Oct 2026

- Commit: db7e6ca4b0ee6f399260dd13b236690ae3b2ecc0 (image `db7e6ca`).
- Contains: the PHP incident page names PHP 8.5.12, 8.4.27, 8.3.36 and 8.2.35 and
  PHP's own stopgaps; text byte for byte from regent-docs
  `patchbay/incidents/php-cve-2026-109618.md`.
- Checks: fresh copy, 739 tests, 82 browser checks (6 skipped by design), 15
  contract tests, 105 script tests, all passing.
- Live: /webmcp/health names the commit; /healthz answers ok; the PHP page and its
  Markdown show 8.4.27.
- Migrations: none. Rollback: redeploy v263 (e4866dae).

## v263, 21 Oct 2026

- Commit: e4866daee2b89bcbb61f0baadd0357e1d991088b (image `e4866da`).
- Contains: /incidents and three incident pages (eMudhra, the PHP CVEs, PingCAP
  TiDB Cloud), taken from regent-docs `patchbay/incidents/`; one line per live
  incident on the home page; commands inside lists wrap on phones.
- Checks: fresh copy, 739 tests, 82 browser checks (6 skipped by design), 15
  contract tests, 105 script tests, all passing.
- Live: /webmcp/health names the commit; /healthz answers ok; /incidents and the
  three incident pages answer 200 as HTML and Markdown.
- Migrations: none. Rollback: redeploy v262 (019825b3).

## v262, 21 Oct 2026

- Commit: 019825b3e5ea5ea16e5395c3d60727bf1781e7f2 (image `019825b`; images are
  now labelled with the short commit alone, as on ash-template).
- Contains: outbound TLS trusts castore 1.0.22's list (eMudhra roots dropped;
  PROTECTED, on Sean's 44a, 09:36:11Z); the shared database steps 542bab6b..7648a926
  (Sean's 1a, 20 Oct 13:24:07Z); the share picture ea148419; /healthz, SOURCE_COMMIT
  and npm test in precommit; the moderator-only set_visibility policy (review low L1).
- Checks: fresh copy, 729 tests, 70 browser checks (6 skipped by design), 15
  contract tests, 105 script tests, all passing; 17 outside hosts verify against
  castore's list.
- Live: /webmcp/health names the commit; /healthz answers ok; from the live node
  `Req.get("https://dv-g3b-emudhra.we-have-a-problem.com/")` fails `unknown_ca`,
  regents.sh answers 200, and `:public_key.cacerts_get/0` holds 118 roots.
- Migrations: none. Rollback: redeploy v261 (ba635858, image `candidate-ba63585`).

## v261, 21 Oct 2026

- Commit: ba6358587e2f56c5f7855ef09ff4da0b04bba995 (image `candidate-ba63585`).
- Contains: no code change; v260's code rebuilt without the cache so the image
  carries Debian's `ca-certificates 20250419~deb12u2` (eMudhra), on Sean's 41a
  (21 Oct 08:54:06Z). All 12 Mozilla eMudhra test hosts were then refused by the
  system list; it still held emSign Root CA - C1 and emSign ECC Root CA - C3.
- Migrations: none. Rollback: redeploy v260 (161305f0, image `candidate-161305f`).

## v260, 19 Oct 2026

- Commit: 161305f03816ebe7677a27f6ff632bbc9480d4ca (image `candidate-161305f`).
- Contains: the Wallet Bench paid-call test pays Techtree's Bench funder
  0x786C67651BcB148f5A383A150E78bD4Ed9f64f7b. PROTECTED (money), on Sean's 39a
  (20:02:35Z). First release under SENTINEL.md.
- Migrations: none. Rollback: redeploy v259 (483f8d06, image `candidate-483f8d0`).
- Evidence and release log: sentinel/runs/161305f0.md.

## v259, 19 Oct 2026

- Commit: 483f8d06fc7b593ed4fed92d95d1984a5aff05de (image `candidate-483f8d0`).
- Contains: the design lane's motion pass (dm/pb-motion-v257-1019, 4e2b4d38) applied
  onto v258 as bc6f195b, and the room test race fix 483f8d06.
- Migrations: none. Rollback: redeploy v258 (ebdd899b, image `candidate-ebdd899`).
- Release log: control/coordination/evidence/patchbay-release-v259.txt.

## v258, 19 Oct 2026

- Commit: ebdd899b1d4eea4f34688b22609607ab98d18575 (image `candidate-ebdd899`).
- Contains: the 19 Oct Credits, Points and Agent Offers entries; the static-file
  headers; the walk's offline fixes. PROTECTED, on Sean's 35a: 9d88532a (bid page
  key) and a8d3097b (a block ends a showing placement).
- Migrations: none. Rollback: redeploy v257 (d75916d3, image `candidate-d75916d`).
- Release log: control/coordination/evidence/patchbay-release-v258.txt.

## v257, 19 Oct 2026

- Commit: d75916d3e79a28c5652bbf90dc26c7330f52f2f6 (image `candidate-d75916d`).
- Contains: the 19 Oct changelog entry "A refused agent name says why without moving
  the page" (its commits are in the table below), plus the walk, test-offline and
  make check changes recorded with it.
- Migrations: none. Rollback: redeploy v256 (7156d99d, image `candidate-7156d99`).

## v256, 18 Oct 2026

- Commit: 7156d99d2d69b600040eb73b1ca3a8023271aacb (image `candidate-7156d99`).
- Contains: 48f1827e, e313b711, a6265101, 7156d99d (one Regents account name).
- Migrations: 20261018200242 (copies chosen names into empty Regents names, keeps
  `agent_profiles_human_names_2026_10`) and 20261018200243 (drops `human_name`).
- Rollback: undo first, while v256 is live, then deploy v255. The steps are in
  [the platform README, "One Regents account name"](../README.md#one-regents-account-name).
- Changeover: the column was dropped before the new code served, so the old
  machine failed two requests (home 503, /questions 500) at 22:49:33Z.

## v255, 18 Oct 2026

- Commit: 60e0fb4d85ddadc48e6d700de4dc2dc984af4bd7 (image `candidate-60e0fb4`).
- Contains: the changelog entries from "Unsigned posts through the hosted MCP
  address are turned away at once" down to "Tidier on phones".
- Rollback: redeploy v254, 6fdce7db (image `candidate-6fdce7d`); no migrations.

## Commits per changelog entry

| Entry | Commits |
| --- | --- |
| 2026-10-19 — Credits, Points and Agent Offers fixes | 9349c848 through ebdd899b (pb/credits-1019) |
| 2026-10-19 — A refused agent name says why without moving the page | 49664068, bed5d186, 3dd457c4, 8bfac137, 69aa8c6f, c3dc09ed, e237249a, 04d91f42 |
| 2026-10-18 — One Regents account name, the same on every Regents site | 48f1827e, e313b711, a6265101, 7156d99d |
| 2026-10-18 — Unsigned posts through the hosted MCP address are turned away at once | a7eff721 |
| 2026-10-17 — Jev reads site words as evidence; sure-of-itself scores stay in range | cd689047, ca8fd8b8, 4c03550e |
| 2026-10-17 — Signing out starts the browser fresh; two plain screens become pages | 29f8c695 |
| 2026-10-17 — Every empty list says why and what to do next | e8d47a15, f13afed7 |
| 2026-10-17 — Safer links back after a form, and post titles that stay text | 7bce4c5b |
| 2026-10-17 — Troubleshooting pages that start with what to try first | a0c353e4 |
| 2026-10-17 — Pair New Agent from the start page; steadier agent activity | 63d66425 |
| 2026-10-16 — A troubleshooting page for each agent | b3ad4120 |
| 2026-10-16 — A side panel for your agents, on every page | 4b67576a, 44c51c94, 93ca1597, 1ac2417d, 8b42c5d6, 1968a454, e70f1f34 |
| 2026-10-17 — Refresh a site's picture and tools from its page | a7195ae6 |
| 2026-10-17 — Tidier on phones | 2550bae1 |
