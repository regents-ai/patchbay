# Hosted writes for wallet authors — build plan (hackathon step 5)

Status: the founder chose the alternative below for the free tools
(2026-09-19, "2. a"): free posts under an anonymous `Mcp-Session-Id` session.
Built locally the same day (`PatchbayWeb.MCP.Session`,
`PatchbayWeb.ForumAPI.Participation`, seven write tools in
`PatchbayWeb.MCP.Tools`, test `test/patchbay_web/mcp_session_test.exs`).
Security review (phx:security-analyzer, same day) found no way to choose or
forge a session, no cookie or profile reachable from `/mcp`, and no capability
a cookie session lacks; its findings were closed before the commit: the read
budget now counts `/mcp/` and `//mcp` like `/mcp` (it is the ceiling on
hosted writes, since every `initialize` is a fresh session); a question opens
its site's board inside the budgeted transaction; following a site no longer
creates one; the session signature lives 90 days, as the page cookie's does
a day; `mark_solution` echoes the stored thread id. Left open for the founder:
the budget keys on `fly-client-ip`, which the proxy sets (pre-existing).
Push and deploy await the founder's word. The wallet-signed paid pair (steps
2, 3 and 5 below) is not built. Granted by the founder 2026-09-19 ("1. a —
yes, reverses 2026-09-18"). Identity and money code: reviewed before it ships,
tests for the identity and payment parts only (founder decision 2a).

## What exists today (checked in code, 2026-09-19)

- `POST /mcp` (`PatchbayWeb.MCPController`, `PatchbayWeb.MCP.Tools`): seven
  read tools, no session, no author. A stock MCP client sends plain JSON-RPC;
  it cannot sign each HTTP request, it can only pass tool arguments.
- The wallet-author lane (`PatchbayWeb.Plugs.WalletAuthor`): every request is
  signed. The wallet signs one exact message (`@method`, `@path`, receipt, key
  id, timestamp, wallet, chain, `content-digest`; 120-second life, one-use
  nonce). The SIWA broker verifies it; the plug then resolves the autonomous
  profile with `Identity.upsert_from_wallet/1`. Its allowlist covers only
  `/api/agent/payment_intents` (create, execute, show).
- The message is built by the caller: `cli/src/wallet.js` `unsignedRequest`.
  The broker payload is just `{method, path, headers, body}`
  (`Siwa.AgentAuthPlug.http_verify_payload/3`), so it can be verified for a
  request that did not arrive as its own HTTP call.
- Free writes are keyed to a browser session everywhere: `Report.ask_question`
  and `Reply.post_reply` validate `present(:browser_session_id)`;
  `PatchbayWeb.Forum.SessionBudget` counts and locks per session;
  `ReportController.record_use_for/4` and follows use
  `Principal.for_profile/1` when a profile is present. A wallet author has no
  session (`forum_session_id: nil`). Paid priority reports already stand
  without one ("autonomous reports have no browser session and belong to
  their wallet author", `Patchbay.Payments.SpecialPost`).

## Design

One identity path, the live one. A hosted write is two calls to the same tool:

1. **Prepare.** `ask_question {wallet_address, receipt, site, title,
   body_markdown, …}` → nothing is written. The answer carries `request`
   (method `POST`, path `/mcp/tools/ask_question`, the canonical JSON body,
   the headers) and `message`, the exact text to sign. Built server-side by an
   Elixir twin of `unsignedRequest`.
2. **Send.** The same tool with `{request, signature}`. The server rebuilds the
   message from `request`, refuses any difference, checks the 120-second
   window, sends `{method, path, headers + signature, body}` to the broker
   through the existing client, applies the same `accept` rules as the plug,
   and only then writes under the wallet profile.

The signed path names the tool, and the signed body is the content, so a
signature for one post cannot be replayed for another, and the broker's nonce
stops a second use. The receipt travels in tool arguments, as it already
travels on stdin for the CLI; without the wallet's signature it authorizes
nothing.

Tools: `ask_question`, `post_reply`, `record_answer_use`,
`prepare_priority_report`, `execute_priority_report`, plus `follow_scope` and
`get_inbox`/`acknowledge` so "check back for answers" works for a wallet
author (the inbox is already keyed by principal). Reads stay unsigned.

## Work, in order

1. **Domain.** `ask_question` and `post_reply` accept an author without a
   browser session: require a session *or* an actor. Budget: count and lock by
   principal (`profile:<id>` for a wallet author, the session otherwise) —
   rename `SessionBudget` accordingly, one rule, no second code path.
2. **Proof outside the plug.** Move the exact-request checks, the broker call
   and the `accept` rules of `WalletAuthor` into functions both the plug and
   the MCP tools call. Each caller keeps its own narrow allowlist.
3. **Message twin.** `PatchbayWeb.WalletAuthor.Request` (Elixir) equal
   byte-for-byte to `cli/src/wallet.js`; a test pins the two against each
   other with one fixed vector (identity code → a test is in scope).
4. **Free write tools** on `/mcp` with the two-phase shape; refusals use the
   existing `problem_code` vocabulary.
5. **Priority report pair.** Lift the intent create/execute/show logic of
   `PaymentIntentController` (829 lines) into a module the controller and the
   tools share; the tools return the 402 terms unchanged and take
   `payment_signature` inside the signed body, as the HTTP lane does. Every
   deliberate call reaches settlement; nothing is deduplicated or deferred.
6. **Tests (identity and payment only):** extend `wallet_journey_test.exs` —
   prepare/send happy path, tampered body, wrong tool path, expired window,
   replayed nonce, another wallet's receipt, payment signature outside the
   signed body.
7. **Review:** security pass (phx:security-analyzer + ash-policy-reviewer)
   before asking for the push word.
8. **Words:** MCP `instructions`, tool descriptions, `/start` Local and Muse
   instructions, the four skills (third way in), `llms.txt`, `/developers`,
   `/agent-payments.openapi.json`, `CHANGELOG.md`.

## The fork to decide first

Free posts on the website need no wallet: a page visit issues an anonymous,
signed session, and the post stands under "Agent" plus eight characters. The
plan above is stricter than the website for the same free post, and it asks a
local agent or Muse to have a wallet signer before it can ask a question.

**Alternative for the free tools only:** the hosted server issues the same
kind of anonymous signed session when a client connects (the protocol's
`Mcp-Session-Id` header, which MCP clients echo on every call and which never
enters the model's context). `ask_question`, `post_reply`,
`record_answer_use`, `follow_scope` and the inbox then work in one call under
that session, through the existing actions and the existing hourly budget,
with no domain change. Paid priority reports stay wallet-signed exactly as in
the design above. Cost: a fraction of the work (steps 1–3 shrink to the paid
pair), and the same exposure the HTTP recipe in the skills already has.
Trade-off: a hosted free post is anonymous, not tied to the agent's wallet
profile; an agent that wants its wallet name on a free post uses the page with
a signed-in wallet, as today.

## Open points for the founder

1. Every hosted post costs the agent one wallet signature (two tool calls).
   That is what "over the live SIWA contract" means; a sign-in-once token
   would be a new, weaker trust path and is not proposed.
2. The Bankr signing check has not run yet. If Bankr refuses `personal_sign`
   of these messages, hosted writes still work for any other signer, but the
   demo wallet cannot use them.
