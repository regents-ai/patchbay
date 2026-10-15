# Patchbay history and guidance adoption — 15 October 2026

Existing checkout: /Users/sean/Documents/regent/worktrees/patchbay/wave-1012.
Branch: pb/bench-read-parity-1015. Reused after the frozen benchmark candidate.
All work here remains local, unpushed and undeployed. No new worktree or DB.

## Immutable slices

- Benchmark:19093c0 →4e18a9e →2612e641a9d6270e0f3ef72e2954756522f81529,
  independently cleared by root and Techtree within their stated scope.
- Guidance:926ba8e9f65e4d371891d61bbe576cf5626b138c (parent2612e64).
  Root reviewed without a concrete finding. Three files: product skill, agents.md,
  llms.txt installation hunk. Owner-only USDC recipes/paid promises/old fees removed;
  free publishing permission rules retained. No payment implementation changed.
- Plugin index:b46893f78b531c2e4ac652afe6c70ad8df2b0261 (parent926ba8e).
  Only plugins/README.md changes: actual private candidate linked, unpublished.
  No plugins/patchbay file or package archive changed.
- History:04880e09e0f73dc451b14195e7e7b823c0a0e6df (parentb46893f).
  Independent review found a logging P2; hold this candidate pending canonical logger correction. Nine files: controller, canonical error logger,
  native manifest, CLI descriptions, typed public OpenAPI, agents/llms history guidance,
  CLI COMMANDS and dated changelog. No router, signing, actor, policy, pin or config edits.

## Done criteria and implementation

- [x] Add canonical entries/pagination without removing existing next/more? aliases.
- [x] Preserve signed POST /tools/account/credits/history and the exact benefiting actor.
- [x] Preserve existing private-stdin CLI input and request method/body/path semantics.
- [x] Use the template’s cursor classifier: non-string and actual invalid-after/keyset
  errors become422 invalid_cursor; mixed/empty/unrelated errors remain503 unavailable.
- [x] Copy UnexpectedFailure from the template; no replacement cursor decoder/parser.
- [x] Type the actual installed grouped event projection, not the stale primary code.
- [x] Correct installation/active skill instructions and verify served source aliases.
- [ ] Independent history review complete.
- [ ] Actual signed HTTP/private next-page boundary acceptance, not performed.
- [ ] Matching CLI publication and an explicitly approved site release, not authorized.

Canonical source: template3d116822 guidance, a7bfd9b cursor behavior, corrected5654a42
contract after8e1a60e. Never adopt8e1a60e’s incorrect entry schema by itself.
Exact installed Patchbay dependency HEAD b5824049d55012f2e8b1e4d7e3e2fcc549d93360
was inspected under platform/deps/regent_credits/credits/lib/regent_credits/history.ex.
It emits grouped id/kind/at/amount/direction plus nullable facts, not operation/deltas.
Received payments do not identify the payer; the library keeps request text scoped.

The site already uses POST; no GET route was removed or converted. Existing merged
request params are retained for compatibility; the documented new-client input is
exact JSON {} or {after:string}. The canonical input max is2048; omit null. No extra
cursor parsing was added. Actor creation and current-pairing admission are unchanged.
The existing CLI private-stdin body definition remains; canonical --after flag/import
work belongs with the package owner. Machine/browser descriptions use the new envelope.

## Verification and limits

Product compile warnings-as-errors, formatting, strict Credo, Sobelow, TS, assets,
pinned check-cli and diff checks pass. Security scan reports no findings.
Temporary diagnostics start no Patchbay application, Repo, signer or HTTP server:
five direct non-string cursor refusals; actual Ash overlength action-input validation;
source-extracted cursor-only/mixed/unrelated/empty classifier cases; actual pinned
History projection functions on a fictional gift with an isolated empty facts lookup.
The200 and422 JSON fixtures validate against the typed schema. This proves shape and
bounded refusal behavior, not private data retrieval, signature validation or page2.
No new product-level suite, ledger access, SQL, migrations, signing, money/provider
calls, wallet actions or Points activation. Existing money-test/earning holds persist.

Actual AgentSkillsController calls at /skill.md and
/.well-known/skills/patchbay/SKILL.md return the authored source byte-for-byte.
The controller embeds this repository file at build; GitHub skill installation
needs a push, and public served aliases need an approved rebuilt deployment.
No private-plugin package was rebuilt or published. Its owner reports the private
archive contains no skill copy; that archive comparison is the owner’s evidence.
The public PyPI1.10.2 wheel SHA was read directly and matches8263918292c7759c30e8b23c91a8c8474d5f43263bd2b962bc5733102b7384fa.
The HTTPX SOCKS extra is an explicit workaround for that release, not a fixed wheel.

Artifacts: /Users/sean/Documents/regent/artifacts/patchbay-history-adoption-1015/.
Includes actual-pinned source projection fixture, no-Repo diagnostics, schema fixtures,
Credo/security/assets output. No credential or real private ledger values stored.

## Integration boundaries

Plugin chief has separately pushed authmaina3f6923f2d7e88c6947be1470479c2bd8eafba72
and owns its release. This branch remains based on closed dependency main5bdea7d;
no auth pins/config were adopted here. Integrate later only under the owner’s release
scope and rerun relevant checks against those exact pins. Never ship this branch
wholesale as the OAuth fix. Preserve the unrelated untracked14October pickup handoff.
Root coordinator has source command definitions and the installed1.10.2 --sort/bench
publication gaps. Current user no-DB restriction and explicit protected-action authority
still apply; none of these local commits authorizes a new push, migration or release.

## Review hold — sensitive error logging

Root independently reproduced a P2 in the newly copied UnexpectedFailure helper:
Exception.message/inspect can expose value-bearing Postgrex/Ash failures or mixed
cursor errors in logs. Reproduction used a synthetic sentinel, no real private data
or live incident. History04880e0 must not ship as-is. Template owner is preparing
the canonical bounded class/correlation-only correction. Adopt the exact reviewed
source after it is supplied; do not fork a local sanitizer, change auth, broaden
package scope or authorize a release. Generic503/pagination compatibility stay intact.
