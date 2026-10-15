# ChatGPT identity and free participation — local completion, 15 October 2026

Sean requested direct implementation, one Regents identity reused across chats,
SIWA preserved, money tests and Points off, no plugin publication. This change
also adopts the Porcelain / cobalt palette he selected in “Design and motion chief”
(chat 01a13dc7-293f-7930-b4e0-5ec88bbf1dd1). No Claude session was used.

## Result

- [x] Shared encrypted account signer and restricted internal signing service.
- [x] Template reference for persistent identity registration, status and pairing.
- [x] Patchbay tools for identity setup, own-code pairing and authorized free posts.
- [x] Separate OAuth permissions for identity, posting and existing events.
- [x] Exact-request SIWA and current pairing on each product request, existing Ash
  writes and request keys, no sponsored Offer selection on this path.
- [x] Canonical free Skills, package descriptions, consent and public guidance agree.
- [x] Shared blue tokens and Patchbay form/card/button accents, both themes checked.
- [x] Representative local flows, scoped checks and independent security review.

The public endpoint remains `/chatgpt/mcp`. Enabled discovery lists seven anonymous
reads, three identity tools and two posting tools. `find_known_fix` is excluded
because that feature is moving to paid access. Native `/mcp` remains unchanged.
No wallet actions, Credits, Points activation, paid tools or Offers are exposed.
Visitor-authored content remains untrusted source material.

`register_identity` prepares a persistent connection keyed by verified Privy subject,
independent of client, chat or session IDs. It does not pair automatically.
The person creates a current one-use code at `/account` and authorizes
`pair_identity`. Foreign, expired or used codes are refused. `get_identity` uses
the non-awarding identity probe. Registration after unpairing does not restore pairing.

`regent.identity.manage`, `patchbay.posts.write` and `patchbay.events.read` are
separate grants. Existing events-only tokens cannot write or gain permissions by
refresh. Every post enters `/chatgpt/agent/mcp` with SIWA proof, then the existing
pairing, account, quota, moderation and Ash checks. Only free questions and replies
are admitted, with no financial fields or paid thread targets. Request keys belong
to pairing, so reconnecting does not create duplicates. An uncertain result requires
reading first; an approved retry preserves the key and exact fields.

Boruta owns OAuth, SIWA owns proof/replay, Ash/Postgres own product data, Req owns
HTTP and the existing event outbox/AshOban delivery remains canonical. No new queue,
polling loop, business action or per-chat identity store was built.

## Source and package

Patchbay branch `pb/hosted-plugin-1015`, base `a3f6923`; isolated checkout
`worktrees/patchbay/hosted-plugin-1015` in the Regent workspace. Rebased as
`pb/hosted-plugin-on-b` onto `0aad24a` (the site directory release, which removed
`find_known_fix` everywhere); OpenAPI moves from 4.0.0 to 4.1.0 for the two
ChatGPT paths.
Template branch `pb/hosted-identity-template-1015`, base `e770693`.
Shared elixir-utils local tip `6b55ae52408fa587545ca14813148d502603ae07`.
Palette source branch `pb/porcelain-cobalt-1015`, commit
`9842b2890bbcb87018c6e02c201d60993387ac6f`, based on the golden shared UI.
Central siwa-server commit `6bb83a4` and template commit `a77d71c` are local; unrelated agent instructions
are preserved. The server now pins the reviewed shared libraries and Bandit fix
`d88b21953c65061f21136ea76a89a4f95a2ac7a1`; its release checker accepts Git dependencies.

Local candidate: `artifacts/patchbay-plugin-0.2.0-identity-local-1015.zip` in the
workspace. SHA-256:
`bacf834f9fdc9dbf2833aa2bf67bd776716aa4dca975f9e6306f085040c68741`.
A second build produced identical bytes. It carries three free canonical Skills,
five positive and three negative review cases, and no credentials.

## Verification and limits

The loopback exercise used actual Boruta grants, the HMAC keyring endpoint, SIWA
signing and verification, pairing and Ash posting. Verified: identity persists across
MCP sessions; registration does not pair; own one-use pairing works; events-only and
identity-only grants cannot post; free question and reply succeed; identical retries
return the original across sessions; changed-content retries are refused; unpairing
and disconnect end access. No Points or Credits tables were created in this exercise.

The fixture used stand-in verified Privy accounts, a representative isolated schema
and a moderation stand-in. Fixture setup errors (float storage and generated sequence
defaults) were corrected before the successful run. It does not prove production
migration execution or real ChatGPT write consent. A separate local permission-boundary check marks a fixture target, proves refusal
before participation and rolls the marker back. No paid posting, money tests or
value transfer ran.

Compile, formatting, strict Credo, Sobelow, usage-rule sync, Ash migration-generation
check, asset build and TypeScript checks pass. Template consent checks cover scope
separation, old-client eligibility, refresh refusal and cached-token revocation.
The final service signing/verifier/controller checks pass: 12 tests, zero failures.
Independent security review found no concrete issue in the scoped source and final
delta; it did not independently execute the fixtures or validate production.

Palette roles match the selected source. Text/accent pairs meet 4.5:1 and essential
borders 3:1. Real local connection UI was inspected at desktop and 320px in both
modes, with no page overflow and Privy settings present. Canonical logos, other brands,
layout and motion remain. Native website tools and navigation remain separate from
this plugin's restricted MCP contract.

## Release remains separate

Nothing in this pass was pushed, deployed or published. Production records were
untouched. No new product migration is generated; existing OAuth and shared pairing
history migrations remain prerequisites. Publish the reviewed library and palette
commits before a separately authorized deployment, then integrate template and site
branches, configure the protected signer and opt in with
`PATCHBAY_MCP_IDENTITY_ENABLED=true` alongside OAuth. Do not paste credentials in chat.

Real ChatGPT identity/posting consent and posting still require that deployment and
user approval of an actual public post. Preserve the existing private watch. A bounded20:38UTC check found no original
or replacement subscriptions after its previously recorded20:33UTC expiry, and no
new source event or host receipt. Host-side cause/recovery remains unverified.
Do not manufacture public test content or claim ordinary chats resume automatically.
The plugin remains an unpublished candidate.

The historical local Site prototype remains a read-only preview, not this candidate.
Before reusing it, refresh it from the server's rendered contracts/resources; its
older sync script assumes eight reads and copies raw card HTML. It was not published
or used as evidence for this completion.
