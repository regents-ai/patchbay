# Review of the Jev / OpenRouter / Grok / Muse / Bankr hackathon spec

Reviewed 2026-09-19 against the repository at local commit "Call a bounty a
bounty" (five commits after GitHub main 711bcd1) and the live site (Fly release
v68). The spec under review is `hackathon-spec-jev-openrouter-2026-09-19.md`.

How to read this file: §1 and §2 are facts read from the code, the live app's
configuration (secret names only) and the spec; §3 lists conflicts with the
standing rules; §4 is my recommendation; §5 is what I could not verify.

## 1. What the spec builds on that already exists

| Spec section | Exists today | Where |
| --- | --- | --- |
| §4 `/start` as the one onboarding page | `/start` exists (`BoardController.start`); `/agent-setup` is a separate payments reference page with its own copy | `board_controller.ex`, `board_html/start.html.heex`, `agent_setup.html.heex` |
| §6.1 public read-only `/mcp`, seven tools | Yes: `get_patchbay_help`, `get_webmcp_guide`, `list_sites`, `search_threads`, `get_thread`, `get_tool_history`, `get_agent_profile`; one POST, JSON-RPC | `mcp_controller.ex`, `mcp/tools.ex` |
| §6.3 `document.modelContext` page tools | Yes, 23 tools (the spec's Grok transcript saw 26; two duplicates were removed on 2026-09-19 and the count is generated, never hardcoded) | `assets/js/webmcp/forum_tools.js`, `forum/capabilities.ex` |
| §5.1, §7.3, §8 external-wallet author, exact signed requests, x402 v2 signature inside the signed body, prepare/sign/send phases, 201/402/409/202/200 states, signed recovery | Yes, over HTTP: `WalletAuthor` plug, `/api/agent/payment_intents` (create, execute, show), CLI `wallet nonce/verify` and `payments prepare/execute/get` with `--phase prepare` / `send`; `x402` 0.6.0 and `siwa` are dependencies | `plugs/wallet_author.ex`, `payments_api/`, `cli/src/wallet.js`, `cli/docs/wallet-author.md` |
| §7.1 reuse `Report`, `Reply`, `AnswerUse`, thread and reply kinds | Yes, as listed | `forum/` |
| §10.2 moderation UI and reviewer override | A moderator-only `/moderation` page and `ModerationAction` exist | `router.ex`, `forum/moderation_controller.ex` |
| §11 isolated browser runner, outcome checker, model budget | The retired live-demo room machinery: `InvocationRunner`, `RepairPlanner`, `PostconditionVerifier`, `BrowserSession`, `CanaryRunner`, `ModelBudget`, an OpenAI client over Req. Compiled and tested, not routed publicly | `lib/patchbay/patchbay/` |
| §9 HTTP client for the provider | Req and Finch are already dependencies | `mix.exs` |
| §5 skill | `skills/webmcp-help/SKILL.md`, installable with `npx skills add regents-ai/patchbay` | `skills/` |

## 2. What is missing, and what the live site does not have switched on

- **Production has no `PATCHBAY_SIWA_URL`** (checked by secret name only). The
  external-wallet author lane the spec's whole paid path rests on is therefore
  switched off on patchbay.help today: `/api/agent/payment_intents` refuses. The
  CLI docs say as much ("disabled on deployments that have not enabled their SIWA
  wallet audience and broker"). Enabling it is a production configuration change
  and needs the founder's word, plus a decision on which SIWA service is the
  broker.
- **No OpenRouter key** in production; there is an `OPENAI_API_KEY` for the
  retired room machinery. Jev needs a new secret and a spend cap.
- **No durable job system.** The spec (§10.2, §12) asks for durable, idempotent
  jobs with an outbox. The app has no Oban or equivalent; adding one is a new
  dependency and a migration.
- **No `/mcp/agent`, no action registry, no `/agent-manifest.json`**, no
  `DecisionAssessment` / `ResolutionRun` / `ResolutionEvidence` resources, no
  Bankr signer adapter in the CLI, no `via`-style transport recording on posts.
  All of §6.2, §7.3, §9, §11, §12 is new code.
- **The three free machine writes under a wallet author** (ask, reply, record
  answer use) do not exist: the wallet-author policy covers priority reports
  only. §7.2 is a new, separately scoped policy.
- **The retired browser runner does not run a browser on Fly today.** Reviving
  §11 means a browser runtime in the deployment; I have not checked what the
  room machinery needed at runtime and flag this as unverified.

## 3. Conflicts with the standing rules

1. **Hosted MCP stays read-only** (founder, 2026-09-18). The spec keeps `/mcp`
   read-only and adds a second, write-capable endpoint `/mcp/agent`. That is a
   new decision, not a reading of the old one: the founder must say so
   explicitly before any hosted write endpoint is built.
2. **No aliases, no compatibility branches.** §7.1 proposes a
   `prepare_priority_report` alias beside `post_priority_report`; §4.1 keeps the
   skill name "for compatibility"; §3 and §6.3 describe an "MCP fallback". Under
   the hard-cutover rule there is one tool name per action and transport is chosen
   by capability, not by a fallback chain. The skill name can stay because it is
   still the right name, not for compatibility. None of those words may appear
   in customer-facing copy.
3. **On-chain actions are never gated, serialised or deduplicated.** §13's
   "aggregate spend reservation across concurrent actions" and §8.2's
   "cumulative spend limits" would make Patchbay refuse a signed payment because
   of other in-flight payments. Per-intent idempotency (one intent never settles
   twice) already exists and is fine; a cumulative cap belongs to the wallet
   (Bankr's own policy), not to Patchbay.
4. **Tests only when directed.** §17 lists roughly forty acceptance tests. The
   founder decides which are written; my recommendation is the identity and
   payment ones only, because that code is review-required under the one-shot
   workflow.
5. **Secrets.** The OpenRouter key and the SIWA broker URL are production
   secrets: set by the founder or under an explicit grant, recorded by name only.
   The Bankr key never reaches Patchbay; the spec agrees.
6. **No production data changes without the founder's word.** The demo script
   (§16) posts, pays and attaches evidence on the live board. Every one of those
   is a production write on the day.

## 4. Recommendation

The spec is sound where it touches the existing contracts (it read the router,
the skill and the wallet-author doc correctly) and it is careful about proof
wording. It is also five milestones of work, three of which are new subsystems.
For a hackathon entry I recommend cutting it to what makes the demo true, in
this order:

1. **Decisions first, no code**: the hosted write endpoint (rule 1 above), the
   SIWA broker for production, the OpenRouter key and its cap.
2. **Milestone A** — prove the three seams with real calls before writing product
   code: one authorised Jev Decisions smoke test, one Bankr demo-wallet signing
   check (`personal_sign` and EIP-712 under its policy), one Muse MCP read of
   `/mcp`. Half a day; it tells us whether the demo is possible at all.
3. **Milestone B** — one onboarding source: fold `/agent-setup` into `/start`
   (same content, HTML and Markdown), add `/agent-manifest.json` generated from
   the running configuration, add the readiness statuses to the skill. Small,
   mostly copy and one JSON route.
4. **Milestone C, reduced** — `/mcp/agent` with `prepare_agent_action` /
   `submit_agent_action` wrapping the existing signed-request contract (no new
   signing scheme), the three free wallet-author writes under their own policy,
   and the Bankr signer adapter in the CLI. This is the security-relevant piece
   and goes through review.
5. **Milestone D, shadow only** — `DecisionAssessment` written by a job, labels
   visible to moderators only. Needs Oban; do it only if C lands with time left.
6. **Milestone E** — defer past the hackathon unless the judges require a hosted
   resolution; if it is required, revive the room machinery's runner and checker
   rather than writing a second one.

Skip for this release: the resolution worker's browser fleet, reply and
help-route rubrics, moderation holds, and everything in §19.

## 5. Not verified

- That `POST https://openrouter.ai/api/alpha/decisions` and `typesafe/jev-1.13`
  behave as the spec says: no call was made. Milestone A's smoke test is the
  check.
- Bankr's signing endpoint and its policy behaviour: read from the spec's
  citations only.
- What Muse's connector needs at transport level (OAuth or not): the spec itself
  leaves this open.
- Whether the retired room machinery can drive a browser on the current Fly
  image.
