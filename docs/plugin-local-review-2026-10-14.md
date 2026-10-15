# Patchbay plugin: local implementation and review

14 October 2026. This completion pass was implemented and self-reviewed by Codex. No Claude or Opus session was used in this pass.

## Result and done checklist

- [x] Build a reproducible local plugin ZIP with five positive and three negative review cases, accurate connection settings and no credentials.
- [x] Keep the eight public tools free and read-only, with matching descriptions, help, repair card and local Site prototype.
- [x] Build the shared Boruta/Privy sign-in service locally, wire its reference into ash-template, and use it for Patchbay event consent.
- [x] Bind event subscriptions to the verified account and connected app; enforce token scope, audience, expiry, revocation and refresh without losing owed events.
- [x] Review the changes, fix in-scope findings, and exercise representative security and recovery flows locally.

Money tests and Points activation stayed off. Nothing was pushed, deployed, submitted or published. Production databases and credentials were untouched.

## Where the work lives

Patchbay checkout: `/Users/sean/Documents/regent/worktrees/patchbay/plugin-1014`, branch `pb/plugin-1014`, based on `85b0cb914b8e2236dcfad6549a7c9fb50b7baea1`. Its changes and this review are saved on that local branch.

Shared package: `/Users/sean/Documents/regent/repos/elixir-utils/oauth`. Only this new directory was committed, as `c648155ca4e11805f47672609da1817a21fca120`. Existing unrelated edits were preserved. This commit is local and unpublished. Consumer dependency pins and locks name it; local checks used `REGENT_OAUTH_PATH` to avoid replacing any other shared package.

Template reference: `/Users/sean/Documents/regent/repos/ash-template`, based on local `af0eded7df32bfa4768c945a2808d8e53aa38105`. Its primary checkout is behind `origin/main`; these changes did not pull, reset or overwrite the other lane's work. The account lookup, verified-session check and current-account assignment used by the adapter were also checked against the current golden checkout. Integration into the current template branch still needs normal review and verification.

Site preview source: `/Users/sean/Documents/regent/sites/patchbay-plugin-prototype`. Its eight tool contracts and card are generated from Patchbay's source. It forwards genuine bearer credentials and challenges; it derives no account authority from a Site user header or an MCP session. The published Site was not changed.

Final local archive: `/Users/sean/Documents/regent/artifacts/patchbay-plugin-0.1.1-events-local-2026-10-14.zip`.

SHA-256: `f5fb8c97fe98c1f3755e88ffd55c4a94fc7e0b11a7ece3c3304d759f9f602798`.

A second build produced identical archive bytes. Earlier October 7 archives and the earlier October 14 candidates are historical, not the final event-auth candidate.

## What changed

Public tools and cards cannot post, select solutions, pay, tip or show sponsored offers. Descriptions and empty-search guidance now point unavailable actions to the website. Search and thread reads skip offer selection entirely; removing paid output afterwards could otherwise affect the size of the free answer. The native interface keeps its existing behavior.

The shared service uses Boruta 2.3.8 for authorization codes, S256 PKCE, access tokens and refresh rotation. Consent uses the existing website session and account. It adds no second account system. Public client registration, discovery, consent, connected-app revocation and credential-safe responses are included. The template uses its canonical browser-session authority. Patchbay uses its existing verified Privy profile.

ChatGPT event methods receive a distinct OAuth reader. It carries no paired-agent or wallet authority. Subscription identity includes both account and client. Stored subscriptions retain the token's row ID, not its bearer value. Delivery rechecks current authority immediately before sending. Native subscriptions retain current pairing checks and cannot take over OAuth subscriptions, or vice versa.

The existing ordered event log and AshOban delivery remain canonical. Ash Signals are appropriate for resource reactions; they do not replace ordered replay and recovery. No new queue, polling loop or parallel source of business truth was added.

OAuth stays disabled by default. A future authorized release can opt in with `PATCHBAY_OAUTH_ENABLED=true` after integration and additive migrations. The template's corresponding flag is `ASH_TEMPLATE_OAUTH_ENABLED`; it has no hosted MCP endpoint and must receive a real resource URL before use.

## Review findings resolved

- Unavailable write/reporting instructions and native card controls leaked into the public plugin surface.
- Read paths selected offers before stripping their output; the plugin now skips selection.
- Event subscriptions required SIWA proof unavailable to ChatGPT. OAuth now grants only event-read authority through account consent.
- Cached token state alone could outlive revocation or changed scope, expiry, issuer or audience. Authoritative stored evidence is rechecked.
- Reusing a spent refresh credential now revokes that account's app connection and requires fresh consent. Standard row locks also prevent a concurrent refresh escaping disconnect.
- Delivery rechecks authority after reading the feed and immediately before HTTP. Refresh preserves the cursor and binds the fresh token.
- Help explains when events are enabled, which consent is needed, and the public thread-read fallback. It promises no automatic resumption of ordinary chats.

Replies, asker-selected solutions, self-reports and matched original invocation evidence remain distinct. Events carry identifiers and a self-event marker, not instructions from board text. They authorize no automatic post or retry in another application.

## Verification actually performed

- Shared package `mix check`; Patchbay and template compile with warnings treated as errors; changed-file formatting, Patchbay migration-generation check, usage-rule checks, template route-handoff check and whitespace checks.
- Public MCP dispatch: exactly eight anonymous reads, excluded writes refused, help restricted to available tools, read-only card/resource agreement and preserved native descriptions. Known-fix evidence was compared through a fixture without calling a model.
- Isolated loopback database: actual Patchbay router, consent and CSRF pipeline, client registration, account switching, token exchange, refresh and revocation. Wrong PKCE, code reuse, concurrent code exchange, refresh replay and simultaneous refresh/disconnect were exercised. Cached tokens with invalid stored scope, expiry, issuer or audience were refused.
- Event records: account/client isolation, native/OAuth isolation, stale native pairing refusal, own-client unsubscribe, encrypted callback secrets, expiry cap, fresh-token rebinding, retry without cursor loss, stable event IDs, self-event marking and disconnect stopping delivery.
- Public empty search: correct website guidance and no offer selection. Native behavior remained intact. Event help was checked with the feature enabled and disabled.
- Template reference: additive OAuth migration, real canonical session resolution, refusal of caller-provided account IDs and stale sessions, consent and token exchange.
- Real callback URL guards were checked against unsafe destinations. Callback challenge and delivery used an in-memory stand-in; no external callback was contacted and no production transport was weakened.
- Site TypeScript checks and build passed. Generated contracts and card match Patchbay's source.
- Portable package schemas passed. The documented OpenAI OAuth extension was checked separately because the portable MCP schema currently excludes that extension. ZIP contents, file bytes, checksum and repeatable output were checked.
- Static security scan found only the two existing action-reuse warnings for `not_allowed`, which only rejects unsupported HTTP methods. No new finding from that scan was left unresolved.

These were focused local exercises, not the broad test suite. No retained product-mirroring tests or money tests were added or run. Oban ran only in manual mode for the local event exercise; no payment or chain workers started. No actual SIWA envelope, Privy provider login, ChatGPT-hosted card or real event callback was accepted end to end.

## Before a future release

1. Integrate and publish the reviewed shared package and template changes through their owning branches, then reconcile the consumer pin if the shared commit changes. The local pin is not remotely fetchable yet.
2. Resolve the existing Bandit 1.12.5 advisory reported by dependency resolution (`EEF-CVE-2026-105659`) as separate server-maintenance work. No unrelated dependency was upgraded here.
3. Review the additive migrations and opt-in flag through the normal authorized release process. No live migration ran in this task.
4. Complete real Privy sign-in, ChatGPT consent, callback verification/delivery, token refresh, disconnect and repair-card checks after an authorized deployment. The Site proxy has not established host OAuth compatibility.
5. Finish publishing-account/domain approval and the reviewer-accessible demonstration, upload a draft, and complete directory review when Sean authorizes it. Approval and publication are separate.

Source references: [OpenAI packaging](https://developers.openai.com/plugins/build/plugins), [authentication](https://developers.openai.com/plugins/build/auth), [MCP Events](https://developers.openai.com/plugins/build/mcp-events), [submission](https://developers.openai.com/plugins/deploy/submission), and [refresh-token replay guidance](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14.2).
