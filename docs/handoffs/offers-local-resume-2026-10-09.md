# Agent Offers local resume — 9 October 2026

Owner: Patchbay Codex chat `01a1214b-a95b-7880-a358-09f1cba115f4`.
Watchdog: Astra chat `01a11974-835f-7bf3-8b7d-a0d5549904f5`.

Sean asked to resume Agent Offers. Bankr CLI/cloud-agent work belongs to Sean
and Techtree. No push, deployment, production database changes or real payments
were authorized.

Done for this pass: preserve the existing Offers implementation, repair concrete
access failures, verify its existing flows locally and provide a sign-in-ready
preview. The real signed-in browser check is awaiting Sean.

## Source

Use the primary checkout `/Users/sean/Documents/regent/repos/patchbay`, branch
`pb/offers-1009`. Its preserved Offers base was `44a936c`; only the two sign-in
repairs from WD024 were cherry-picked (`6c72a22`, `88a1310`). Do not merge the
whole older WD024 branch. Bench board and daily-tests worktrees remain separate;
the owner is at the two-worktree limit. Root `_build/` was already untracked.

The follow-up checks component events and async results against the current
profile, prevents duplicate nested-header hooks, and withdraws an open moderation
page when its wallet or allowlist access changes. Ash is updated to 3.34.6 for
[GHSA-xj24-8f5c-pp5p](https://github.com/ash-project/ash/security/advisories/GHSA-xj24-8f5c-pp5p).
The resolver also updated Req to 0.7.5 and ex_ast to 0.16.0. Shared Regent pins
were retained; generated usage rules were synchronized.

## Verified

Existing Offers tests, agent API tests and create-page tests: 68 tests, three
properties and ten doctests, zero failures. Coverage includes Credits holds,
refunds and settlement, repeated bids, insufficient funds, owner isolation,
wallet-agent refusal, screening, moderation and immutable wording versions.

A separate rolled-back fixture driver checked fresh component profiles, expired
events, every component async-result kind, nested hooks, page expiry and loss of
moderator access before navigation, events, messages and async results. Astra
confirmed closure of the two additional access gaps in source; it did not run
our runtime checks.

Assets, warning-free compilation, TypeScript, formatting, Credo, unused dependency
check, Ash code generation, usage-rule check and Hex audit passed. Hex reported
no retired or advisory packages, with a local cache-read warning.

Browser: markets and bid navigation worked; public WebMCP list_offer_slots matched
the page; Privy's sign-in dialog opened. HTTP: public pages and OpenAPI returned
200, invalid slots and private moderation returned 404, signed-out private bid
options returned 401. Sign-in metadata was nonempty; its value was not printed.

## Preview and remaining work

Preview: <http://localhost:4050/offers>. Uses existing local database
`patchbay_offers_preview_1009b`; screening and settlement jobs are manual,
provider keys are omitted, and background agent/chain work is disabled. Saved
Offers therefore wait for screening in this preview. Actual provider screening,
wallet payments and production migration/deployment have not been exercised.

Tests reused inactive `patchbay_testsentinel44a` with `MIX_TEST_PARTITION=sentinel44a`.
The older `_offers` test database conflicted with folded migration history and
was preserved; no reset or destructive database command was run.

Drivers and screenshots: `/Users/sean/Documents/regent/artifacts/patchbay-offers-resume-1009/`.
Logs: `/tmp/patchbay-offers-*.log`. The preview launcher is `serve.exs`; load this
site's allowed direnv settings without reading `.env` or `.envrc`, remove
DATABASE_URL and provider keys, set PORT=4050 and PHX_SERVER=true, then use
`mix run --no-start` with that launcher. Do not reuse another site's Privy app.

The existing browser-session authority remains; a shared paired-agent identity
cutover is a separate change. No release approval is implied by these checks.

## Founder feedback follow-up

Credits purchases are Base-only in Patchbay: no Ethereum option or balance,
no automatic selection of the wallet's Ethereum chain, and no new Ethereum
purchase review. Unsupported form chains receive a Base-only refusal that the
browser preserves. Already-sent historical receipts retain their reporting path.
The shared Credits library and historical purchase records are unchanged.

Offers pages explain write → safety approval → site-fit approval when needed →
bid in Credits. Pending Offers appear on the bid page with their safety status
and a visible disabled submission button, rather than directing their owner to
write another Offer. A live approval notification selects approved wording and
reveals the form without changing the entered amount. The preview explicitly
labels paused screening. No Credits are held before a bid is submitted.

Verified: 29 existing scoped bidding/API/create-page tests; warning-free
compilation, formatting, Credo, TypeScript and assets. A rolled-back fixture
driver exercised pending, approved and expired approval views, preserved a
2.35 Credits input, confirmed no hold before submission, checked Base-only
transaction reviews and switching from an Ethereum wallet, and refused
unsupported chains. Astra source-reviewed the final changes with no blocking
findings. Browser verification showed the revised public instructions; the
browser session accessible to automation still showed signed out after Sean's
sign-in reply, so the real signed-in browser flow remains unverified.

Read-only inspection confirmed `patchbay` and `Use Patchbay`, version 1, both
still have pending safety reviews in the preview. The latter's bare address
would require a person's review even after automatic screening. No saved text
or review decision was changed. The allowed direnv settings do not currently
provide OPENROUTER_API_KEY. Asked Sean for the existing secret-loading path and
approval for one safety call per saved Offer. Those answers are pending.

`screen_saved_offers.exs` in the artifact directory is prepared and dry-run
verified. By default it makes no screening calls or review writes. Only its
`--screen` mode runs the two existing server-owned safety actions, once each;
do not run that mode without Sean's applicable authority and provider settings.
It does not start settlement, unrelated queues or a web server. The ordinary
preview remains paused. No wallet action, real purchase, push or deployment
was performed.
