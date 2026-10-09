# Patchbay signed agent access — source checkpoint

9 October 2026. Branch `pb/signed-access-1009`, base `10fc8c6`, reused checkout
`/Users/sean/Documents/regent/worktrees/patchbay/bench-board-local`.
Sol sequences the shared/template/site rollout. This checkpoint is not deployment readiness.

## Done criteria

- Commit source using the published shared signing and current-pairing components.
- Keep public reads open, private reads owned, and agent authors separate from canonical beneficiaries.
- Lock current pairing inside product mutation commits; preserve authorized payment completion.
- Keep native schemas, hosted admission, HTTP, CLI and served guides consistent.
- Exercise safe representative access behavior; record real signing, browser and deployment gaps.

## Prepared source

Signed native forum tools and hosted MCP writes use exact request proof and current pairing.
Private follows belong to the paired owner's principal. Stable post keys use the pairing episode.
Resources freeze acting agent, local beneficiary, canonical account and episode at the committed effect.
Verified Privy sign-in establishes the canonical account; historical ownership is never guessed.
Shared Credits/history and Points reads are wired; this source activates neither spending nor Points.

Room actions retain the real page attachment, observed registry and existing visible-state verifier.
Invocation and repair commits recheck ownership/pairing after inference. Invoke and final observation
need separately prepared proofs. Approval/publication remain human owner actions. Reset refreshes the
page attachment; retired revisions cannot prepare work.

Legacy new payment-intent and free-assist routes now require pairing. Preparation locks the episode
inside the database transaction without a provider call. Free assist jobs check their recorded episode
before provider work. Completion admission distinguishes already pending/settled/applied intents.
The shared initial settlement guard and narrow completion API are now consumed from
`elixir-utils` `1564d79eb3b653f06ab11b6c422bd4d6283ea199`, following
`ash-template` `4255fd4327882022424e4f600656532e2baecffe`. Deployment still awaits the
centrally sequenced native acceptance gate.

Own migrations only add four nullable attribution columns to eleven product tables. Shared prerequisite
checks are read-only. No historical backfill, shared migration or production change was performed.
Primary Offers work and the published matrix are preserved. Port 4006 is paused only
while this source checkout is in use; the separate visual branch is `pb/bench-logos-1009`
at `6a05db1` and will be restored afterward.

## Checks actually run

- Elixir compile with warnings as errors, strict Credo and Sobelow passed.
- Browser TypeScript checks and asset build passed.
- CLI descriptors passed the checker pinned to published `90f45ce`.
- Ash migration consistency check passed; generated migrations reviewed as additive only.
- Local rollback-only fixture: canonical owner/agent separation, duplicate follow, owner read,
  cross-owner read/write refusal, invalid episode refusal, and solution ownership isolation passed.
  Fictional profiles/pairings, temporary account table/columns rolled back. Exact benchmark rows
  were compared before/after and preserved. No workers/provider/financial calls ran.
- Local DOM fixture: ordinary and 64 KB room preparation retain exact body; finalize/cancel schemas
  require invocation ID; retired revision refuses preparation. This is not real browser acceptance.
- Independent read-only reviewer found room relationship lookup, missing current revision, too-small
  preparation result limit, stale reset attachment and transferred solution rights; fixes landed.
  No further confirmed defect was reported in the examined forum/room paths.
- Existing Sobelow exceptions remain only the two GET/DELETE refusal-only MCP actions; fingerprints
  were updated after router lines moved. No mutating route finding was suppressed.

Evidence: `/Users/sean/Documents/regent/artifacts/patchbay-bench-board-local-1009/adoption-*.log`.

## Still required

1. Publish scoped source under the founder's verified five-site rollout approval, then
   restore the visual preview. Two independent read-only reviews found the three issues
   below, confirmed the fixes, and reported no further actionable completion issue.
2. Real settled-effect creation and HTTP acceptance are still unverified; safe fixtures below
   do not establish wallet, provider or end-to-end payment success.
3. Revocation/deletion test: automatic approval review blocked the prepared rollback command twice,
   including after Sean explicitly approved it. Neither attempt ran. The separate ownership fixture
   omits deletion, revocation, re-pairing and unfollow; none is claimed verified. Do not bypass the hook.
4. Real signer/native browser/hosted MCP/CLI acceptance, room reset recovery, concurrent revocation
   during inference, production migration and deployment remain unverified and centrally sequenced.
5. Keep grants/spending, provider activation and Points activation held until explicitly cleared.

No push, deployment, real signing, funds movement or production DB operation occurred in this work.


## Shared completion integration

The founder approved “Authorize migrations, releases and five-site deployment” and
“Yes—coordinate directly with those chats” in the ash-template chief chat on 9 October
(user message `01a12284-bd61-7651-93ae-70552a552afd`); this record was read directly.
The separate local Credits/Offers settlement hold remains in force. Sol owns production
sequencing. This branch does not activate spending, provider calls, Offers settlement or Points.

Standard tools: Ash actions/policies/validation own product access; the shared payment
library owns frozen authority and Ecto row locks; existing AshOban triggers own paid jobs.
No custom queue, retry loop or signer was added.

- Payments now use the managed `elixir-utils/ash_components/payments` package at the coherent
  shared pin. New preparation and settlement require current pairing in the shared transaction.
- `/api/agent/payment_intents/:id/execute` requires current pairing. The separate signed
  `/complete` endpoint accepts only `{}`, calls `Purchase.complete`, and returns only intent
  ID, status and receipt. It cannot start or retry settlement. CLI/OpenAPI/agent guide agree.
- Each paid offer checks the canonical CompletionActor against exact intent, kind, digest
  and target. Paid resource actions validate the same bound target and payment ID, reject
  ordinary completion reads/writes, and freeze original beneficiary/agent/episode attribution.
- Wallet-origin paid effects carry no browser identity. Agent assist reads require current
  delegation and the frozen beneficiary; another owner cannot inherit the stable agent's
  private assist. The browser-read bypass excludes agent and completion actors.
- Focused no-start checks passed wrong signer/intent/kind/digest/target/beneficiary/episode,
  wrong site and untyped identity refusals, restricted reads, minimal serializer, empty body
  admission and payment-signature refusal. No application, database or provider was started.
- A separate rollback-only database fixture passed original owner assist read/open-run,
  other beneficiary refusal despite the same stable author ID, private open-run isolation,
  and completion browser-read refusal. Exact assist, pairing, benchmark result/check rows
  matched after rollback. No deletion, revocation, real re-pairing, workers or network calls.

Evidence: `/Users/sean/Documents/regent/artifacts/patchbay-bench-board-local-1009/completion-*.log`.
Compile with warnings as errors, strict Credo, Sobelow, migration consistency, CLI
descriptors, browser types, asset build, usage rules and required-fix checks passed.
Focused owner-read and completion fixtures passed after the fixes. Independent review
confirmed the corrections and found no further actionable completion issue. No full
product suite or real settled-effect flow is claimed. No product deployment occurred here.

The compile-dependency gate initially rejected 46 connections against the old 43 limit.
The three added connections are the canonical account resource and the two owned
subscription policy checks introduced in the signed-access checkpoint. The budget is
now exactly 46; no permission check was removed to satisfy it.
