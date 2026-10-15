# Patchbay plugin: shared integration and server security

14 October 2026. This follow-up completes the shared/template integration and
server advisory work left by the earlier local review. Codex implemented it and
used a separate read-only security reviewer. No Claude or Opus session was used.

## Done checklist

- [x] Isolate the OAuth-only work onto current shared code without carrying the
  unrelated local Points/Credits commit or dirty work.
- [x] Integrate and verify the reference against the current template baseline.
- [x] Resolve the server advisory with the official fixed source and enforce it
  through the template's required-fixes registry.
- [x] Fix and independently review the OAuth findings; exercise their failure cases.
- [x] Verify Patchbay's public MCP and event flows with the integrated dependencies.
- [x] Rebuild and validate a reproducible local plugin ZIP.
- [x] Finish the local review and save the tested Patchbay changes.

Money tests, Points activation, production access, publishing, pushes and deployment
are outside this work. No product supervision tree or money/chain workers started.

## Saved source

| Repository | Local branch | Reviewed source |
| --- | --- | --- |
| elixir-utils | `pb/oauth-shared-1014` | `edb97f1c1bb7cc9ce1aa02f4646eea18f7f8923d`, based on `e009b1a2258250122dfe6c242d18eb9b02de74c8` |
| ash-template | `pb/oauth-template-1014` | `28d411458c17e58ead788742aae12e7f145a2463`, based on `905b1bee0c27ba61fafa4261e417fc9d5310a8e7` |
| Patchbay | `pb/plugin-integrated-1014` | This branch, continuing the prior plugin commit `0a873b5654e7aa682c229a71fe4648614aaa8f4c` |

All shared packages in each consumer now use the same reviewed repository commit.
Normal Git dependency checks fetched the exact local commits with the original
repository URLs preserved; no OAuth path override was needed. The temporary
OAuth-only dependency helper was removed. Patchbay adopts the template's Ash 3.36,
AshOban 0.10 and Signals compiler. Its ordered event log and AshOban delivery remain
canonical; Signals do not replace replay and recovery.

The first integrated compile found an obsolete `RegentCredits.Credited` callback.
Patchbay now copies the template's inline Credits listener into its own Points
domain, removes the retired callback/setting and registers the domain and reload
compiler. The existing system actor and purchase event identity are preserved.
No purchase or Points behavior was exercised; the start date and approved rules
remain unset. Both development and test environments compile successfully without
running the test suite.

Only the authorized extra checkout slot was used, sequentially across repositories.
The shared and template branches remain available with verified recovery bundles.
The older template draft was matched against its saved patch before removing only
those exact edits. Other agents' working changes were preserved. The OAuth package
in the shared primary checkout also matches the reviewed package subtree.

## Security fixes and review

Boruta owns OAuth and PKCE; Phoenix owns verified browser sessions and CSRF; Ecto
owns database constraints, transactions and row locks. Existing AshOban owns durable
delivery and retries. No new queue, lease, retry timer or polling loop was added.

The independent reviewer found four concrete problems, all fixed:

1. Protocol revocation could race with refresh and leave a successor authorized.
   Revocation and issuance now share the client row lock and revoke the connection.
2. The public revocation endpoint did not bind a credential to the supplied client.
   Wrong-client and unknown credentials now succeed without changing authority.
3. Extra query/body request objects could reach Boruta outside the validated OAuth
   request. Consent and token calls now receive only validated parameters; approval
   refuses unsupported body fields. No remote request object runs under a DB lock.
4. An already-revoked credential could disconnect later fresh consent. Such
   credentials are now no-ops, while rotated predecessors can still revoke their
   active successors.

Representative local checks passed for malformed request inputs, wrong-client and
unknown revocation, rotated-predecessor revocation, simultaneous refresh/revoke,
and old revoked credentials after fresh consent. Existing PKCE, code replay,
refresh replay, account switching, stored issuer/audience/scope/expiry and disconnect
checks also passed. The reviewer rechecked the fixes and found no further concrete
issue in the bounded OAuth and template integration scope.

## Server advisory

Bandit is pinned to the official fix
`d88b21953c65061f21136ea76a89a4f95a2ac7a1` for
`CVE-2026-105659` / `EEF-CVE-2026-105659` / `GHSA-69m6-wcv4-rwcf`.
No fixed Hex release was available when checked. Upstream still labels this source
1.12.5, so the exact Git source and its patch ancestry establish the fix. No advisory
was suppressed. The proposed template registry checks the source and required commit.

All four upstream regressions passed on that source: connection-window byte
trickles, empty SETTINGS trickles, stream-window byte trickles, and a slow client
that keeps making sufficient progress. These used local framework fixtures and
started no product app or money workers.

Sources: [upstream advisory](https://github.com/mtrudel/bandit/security/advisories/GHSA-69m6-wcv4-rwcf)
and [official fix](https://github.com/mtrudel/bandit/commit/d88b21953c65061f21136ea76a89a4f95a2ac7a1).

## Integration evidence

The shared package's compilation/format checks and dependency audit passed.
The current template compiled with warnings treated as errors. Its actual routes
were exercised with a stand-in account in a named loopback database: additive
migration, registration, canonical session resolution, stale-session and forged
account refusal, consent and code exchange. Its formatting, usage rules, route
handoff, dependency audit, proposed required fixes, OAuth default-off setting and
inactive Points checks passed.

Patchbay's integrated development and test compilation, changed-file formatting,
generated usage rules, dependency audit and proposed required-fixes check passed.
The public MCP exercise verified eight anonymous read tools, refused writes,
restricted card resources, accurate help, preserved native guidance and unchanged
evidence. The pinned Bandit served the actual MCP router on an ephemeral loopback
port; tool listing, read-only help and method refusal passed.

The isolated event exercise passed through actual OAuth routes and CSRF, existing
account consent, account/client and native/OAuth isolation, callback challenge,
encrypted callback secrets, token expiry caps, retry without cursor loss, stable
event identifiers, the self-event marker, fresh-token rebinding and revocation.
Callback delivery used an in-memory stand-in after exercising the actual unsafe-URL
guards. No real external callback or Privy provider was contacted.

The new ZIP is
`artifacts/patchbay-plugin-0.1.1-integrated-local-2026-10-14.zip` in the workspace.
SHA-256: `9a8de866376689d62b3c45b0bcf7f4534564715fb6c2b6fb4d54bd09928aeebb`.
A second build produced identical bytes. Portable schemas and the exact OpenAI
OAuth extension passed validation. Earlier archives remain historical candidates.

## Guidance coverage

| Surface | Disposition |
| --- | --- |
| Shared OAuth README and template reference | Updated for validated inputs, revocation and the integrated pin; checked against source and local exercises. |
| Template server guidance and required-fixes registry | Added official fix provenance and temporary Git-pin enforcement; local gate passed. |
| Plugin README and ZIP | Release prerequisites corrected and rebuilt; schemas and reproducibility checked. |
| Signals guidance and generated dependency rules | Copied the canonical template listener and refreshed usage-rule links; compilation and independent source review passed. |
| Eight tools, repair card, manifest, public Skills and Site preview | Existing read-only contracts remain applicable; no write/payment tool or new business action added. |
| HTTP/CLI business contracts | No operation or CLI shape changed in this follow-up. OAuth uses its protocol discovery and reference documentation. |
| Deployed service, installed plugin and published Site | Unchanged; real host/provider acceptance is pending an authorized release. |

## What remains outside local completion

The new shared and template commits are unpublished. Release builds elsewhere need
those reviewed commits published before fetching them. The ordinary remote
required-fixes gate also needs the proposed template registry; local validation
used that exact proposed revision rather than claiming it is already on main.

After a separately authorized deployment and additive migrations, verify real Privy
sign-in, ChatGPT consent, callback challenge/delivery, refresh, disconnect and the
hosted repair card. Current local checks use stand-ins and establish no real ChatGPT
or Site-hosted OAuth acceptance. Publishing-account/domain approval and directory
review remain separate. Nothing was submitted or published here.
