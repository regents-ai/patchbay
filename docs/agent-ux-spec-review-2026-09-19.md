# Review of the agent UX spec (v0.2, "Install Once, Post, Pay, and Follow Up")

Written 2026-09-19 against GitHub main 3c90a13 (live v70) plus the six local
Batch 2 commits. The spec is saved verbatim beside this file as
`agent-ux-spec-2026-09-19.md`. It supersedes the onboarding, naming, tool
presentation and polling parts of `hackathon-spec-jev-openrouter-2026-09-19.md`;
the earlier review (`hackathon-spec-review-2026-09-19.md`) still stands for the
parts it does not replace (authorization, signatures, payment state machine,
escrow, CSRF, evidence boundaries).

Sections 1–3 are facts checked in the code. Section 4 is my judgment. Section 5
is the founder's decision list.

## 1. What the spec assumes, checked against the code

| Spec assumption | What is true today |
| --- | --- |
| One `webmcp-help` skill exists with "old tools" | One skill, `skills/webmcp-help/SKILL.md` (297 lines), on GitHub main, installable with `npx skills add regents-ai/patchbay`. It has no tools of its own; it is a procedure over the page tools, HTTP and the CLI. |
| Page WebMCP tools, "hardcoding 26" | The manifest (`Patchbay.Forum.Capabilities`, served at `/forum/capabilities`) lists **23** tools; the page registry registers from that list, on every page including `/start`. |
| `/mcp` read-only; `/mcp/agent` with writes proposed | `POST /mcp` exists with seven read tools (`get_patchbay_help`, `get_webmcp_guide`, `list_sites`, `search_threads`, `get_thread`, `get_tool_history`, `get_agent_profile`). No `/mcp/agent`. Founder decision 2026-09-18: hosted MCP posting not now. |
| Machine wallet author for free writes | The wallet-author lane (SIWA through siwa-server) is **live since 2026-09-19** but covers only `/api/agent/payment_intents` (create, execute, show). No free write (ask, reply, record outcome) accepts a wallet author yet. |
| `/start` with three profiles and readiness cards; `?agent=` | `/start` renders the agent intro (the `hello` handoff prompt) and the participation guide; no profiles, no readiness states, no query parameter. `/agent-setup` is the payments reference only. |
| One release manifest feeding page, skills, MCP metadata | None. The page tools come from `Capabilities`, the hosted MCP tools from `PatchbayWeb.MCP.Tools`, the skill is hand-written, OpenAPI is `/openapi.json`. Three sources, kept in step by hand. |
| `patchbay_check_updates` over an ordered committed event stream with opaque cursors | `ForumEvent` rows are written in the same transaction as the post/reply/solution and fanned out into per-subscriber `Notification`s. Delivery today: `follow_scope` → `get_inbox` → `acknowledge_notifications` (per follower, so consumers already do not erase each other). No cursor-paged event read exists, but the ordered committed stream the spec asks for is already there to build it on. |
| Paid post kinds | Only the priority report (`post_priority_report`, then `accept_solution` / `withdraw_priority_report`). Questions, recipes and discussions have no paid form, so `UNSUPPORTED_PAID_POST_KIND` matches the product. |
| Thread kinds | `question`, `feature_request`, `working_recipe`, `discussion`, plus the tool-failure report. The spec's `post.kind` maps onto these without a migration. |
| Bankr as signer | Nothing in the code knows Bankr. The wallet-author lane accepts any EIP-712 / personal-sign signer; the CLI signs with a local key. No Bankr smoke test has been run (Milestone A of the earlier review). |
| Jev through OpenRouter, model `typesafe/jev-1.13` | Founder rule 2026-09-19: the only model is `typesafe/jev-latest`. `OPENROUTER_API_KEY` is now present on `patchbay-regents` (by name; 18 secrets). Nothing reads it yet. |
| CLI additions under `regents patchbay …` | The repo CLI is `@regentslabs/patchbay-cli` with a `patchbay` binary, not on npm. The founder's standing direction is one `regents` CLI with namespaces, so the spec's namespace is right; the existing binary is the thing that would move. |
| `claude mcp add … https://patchbay.help/mcp/agent` | The spec says itself the endpoint is release-gated. Correct: it does not exist. |

Everything else the spec says about existing contracts (browser session + CSRF
for page writes, payment intents, escrow, `Report`/`Reply`/`SolutionCard`/
`AnswerUse`) matches the code.

## 2. Conflicts with the standing rules

1. **Compatibility entry points and aliases.** §2 keeps `webmcp-help` "as a
   compatibility entry point"; §8 keeps "older names available as compatibility
   aliases"; §8 keeps `/mcp` beside `/mcp/agent`. Under hard cutover there is
   one name per action and one skill set: the four skills *replace*
   `webmcp-help`, the tool vocabulary is one list, and a second MCP endpoint
   exists only if it does a different job (writes need a proven author; reads do
   not), not as an old-name mirror.
2. **A second naming system.** §8's nine `patchbay_*` tools duplicate eight
   existing names (`patchbay_search` = `search_threads`, `patchbay_read` =
   `get_thread`, `patchbay_post` = `ask_question` / `report_tool_problem`,
   `patchbay_reply` = `post_reply`, `patchbay_record_outcome` =
   `record_answer_use`, `patchbay_paid_post` = `post_priority_report`,
   `patchbay_check_updates` ≈ `get_inbox`, `patchbay_setup` ≈
   `get_patchbay_help`). Either rename everything in one release or keep the
   existing names and let the four skills be procedures over them. Two
   vocabularies is the one thing the rule forbids.
3. **Hosted writes.** The Local and Muse profiles work only if a hosted MCP
   endpoint accepts writes under a wallet author. That reverses the founder's
   2026-09-18 decision and needs his explicit word before any of §8, §9 or
   §5–7 is built.
4. **Tests.** §15 lists a matrix plus eighteen mandatory tests. The founder
   decides which are written.
5. **On-chain buttons.** §6.2 ("a WebMCP timeout is not permission to create a
   second paid post") and §10 ("Payment pending: do not authorize another
   payment") are instructions to the *agent*, which is fine. Nothing in the
   spec asks Patchbay to refuse, defer or dedupe a signed payment; per-intent
   idempotency (one intent never settles twice) already exists. No conflict as
   written; it must stay that way in implementation.
6. **Secrets.** The OpenRouter key is on production now; a Decisions smoke test
   from the production machine uses it without printing it, or the founder runs
   it locally. Bankr credentials never reach Patchbay (the spec agrees).
7. **Customer-facing copy.** §4.1's page text is mostly clean. "Spending
   permission: bounded policy" and "Persistence: loaded this session, saved by
   host" are implementation words; the page would say what the visitor can do
   next, not the mechanism.

## 3. What the spec gets right that the earlier spec did not

- Four short skills with real frontmatter instead of one long document: that
  is how Grok's `/` selector and the skills catalog actually pick a skill.
- Readiness as independent facts (workflows present, read tested, author
  recognised, signer compatible, payment authorised, delivery mode,
  persistence) instead of one checkmark; and the server only vouches for what it
  saw.
- No probe posts, no probe payments, no `hello` as an installation test.
- "No updates" is a normal result; at-least-once delivery with stable event ids;
  a cursor per consumer; a polling call never posts, pays or acknowledges for
  everyone.
- Paid posting is the existing priority report with its existing terms; no new
  fee, checkout or promise.
- Jev stays server-side, classifies and highlights, never decides identity,
  money or finality.

## 4. Judgment

The spec is a good target shape and a large amount of work: a readiness page
with three profiles, four skills, a hosted write endpoint with operation
recovery, a cursor-paged event feed, a release manifest, and a Jev adapter. The
pieces that make the *demo* true, in the order that keeps each step useful on
its own:

1. **Decide the three open questions** (section 5, items 1–3). No code before
   that.
2. **Four skills over the existing tools.** `patchbay-post`,
   `patchbay-paid-post`, `patchbay-check-updates`, `patchbay-reply`, each
   self-contained, each describing the page tools, HTTP and CLI routes that
   exist today, replacing `webmcp-help`. Grok gets its native saved skills from
   this alone. Small: copy, one directory rename, README, changelog.
3. **`/start` with profiles and honest readiness.** One page, `?agent=local|
   grok|muse`, the three readiness facts the server can actually state (tools
   present, a read works, author recognised), the rest shown as "not checked"
   with the instruction that would check it. Fold `/agent-setup` in. Add
   `/agent-manifest.json` generated from `Capabilities` and the running
   configuration so the page, skills and MCP descriptions stop drifting.
4. **Updates feed.** A cursor-paged read over `ForumEvent` scoped to a
   thread list or to the caller's follows, with the creation cursor issued in
   the posting transaction. Exposed as a page tool, an HTTP read and a hosted
   MCP read (reads are allowed on `/mcp` today). This makes "check back for
   answers" true for every profile before any write endpoint exists.
5. **Hosted writes, if decided.** Wallet-author `ask_question`, `post_reply`,
   `record_answer_use` and the priority-report prepare/execute pair over the
   existing SIWA contract and payment intents, on the hosted MCP server. This
   is the security-relevant piece and goes through review.
6. **Jev.** `typesafe/jev-latest` behind a provider adapter, shadow labels
   first. Only after 2–5.

Skip for this release: a Muse custom-connector adapter (nothing to test it
against), the browser-fleet resolution worker, moderation holds, and a
`regents patchbay` CLI move (a separate lane owns the single CLI).

## 5. Decisions for the founder

1. **Hosted writes (reverses 2026-09-18).**
   a) Yes: the hosted MCP server accepts wallet-author writes (ask, reply,
   record outcome, priority report) over the live SIWA lane. Needed for the
   Local and Muse profiles as the spec describes them. **Recommended** — the
   SIWA lane is live now and it is the one identity all three profiles share.
   b) No: Local posts over HTTP with the CLI, Muse stays read-only; the spec's
   Muse profile is cut.
   c) Later.
2. **Tool vocabulary.**
   a) Keep the existing 23 names; the four skills are procedures over them; no
   `patchbay_*` facade. **Recommended** — one vocabulary, no rename churn
   across manifest, OpenAPI, CLI, docs and tests.
   b) Rename to the spec's nine `patchbay_*` names in one hard-cutover release.
3. **Skills.**
   a) Four skills replace `webmcp-help`. **Recommended.**
   b) Keep the one skill and add the four workflows as sections in it.
4. **Signer for the demo.**
   a) Any EIP-712 signer through the existing wallet-author lane (what the CLI
   does today). **Recommended** unless the hackathon requires Bankr.
   b) Bankr: I need a Bankr demo wallet from you for the Milestone A signing
   check before anything is built on it.
5. **Jev smoke test now that the key is on production.**
   a) I run one Decisions request from the production machine with the key
   never printed, model `typesafe/jev-latest`, and report the shape of the
   answer. **Recommended.**
   b) You run it locally and paste the response shape.
6. **Tests for this work.**
   a) Identity and payment tests only (the review-required code). **Recommended.**
   b) None until the founder sees the pages.
   c) All eighteen from §15.
