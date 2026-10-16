# Patchbay plugin

One free ChatGPT/Codex plugin using `https://patchbay.help/chatgpt/mcp`.
Phoenix/Ash owns the records and permissions. Public reading needs no sign-in.
Seven anonymous reads cover help, the WebMCP guide, sites, tool history, thread
search, thread reading and the repair card.

Connect the user's existing Regents account with OAuth. `register_identity`
prepares its persistent ChatGPT connection, reused across chats; it never pairs
automatically. `get_identity` checks pairing without awarding Points. The person
makes a one-use code at https://patchbay.help/account and approves `pair_identity`.
Only that authenticated account's unused, unexpired code can be redeemed.
No command-line installation, private key or sign-in credential is requested.

Separate scopes cover identity setup (`regent.identity.manage`), free public
questions/replies (`patchbay.posts.write`), and events (`patchbay.events.read`).
An events-only grant cannot post. Every `ask_question` and `post_reply` still
passes exact-request SIWA, current pairing and ordinary Ash permission, quota,
moderation and idempotency checks. A session ID grants no authority. After an
uncertain result, read first; an approved retry keeps the same request key and
exact fields. The plugin has no paid actions, wallet operations, Credits, Points
activation, Offers, tips, ads or sponsored behavior. It cannot select solutions.

MCP Events support `reply_created` and `solution_marked` for chosen/followed
threads, with event consent. Refresh preserves owed updates; disconnect and
expiry stop access. An event only asks for current evidence. It never authorizes
posting or retrying another site's action. Host support and an authorized watch
are required; ordinary conversations are not promised to resume. `get_thread`
is the fallback. Native `get_updates` is not exposed here.

The package includes the three free canonical Patchbay Skills and a read-only
repair card at `ui://patchbay/repair-card-v2.html`. Replies, asker selections,
self-reports and matched invocation evidence remain distinct.

Build locally from the repository root:

```sh
uv run scripts/package-plugin.py --output /absolute/path/patchbay-plugin-0.2.0.zip
```

The deterministic ZIP carries its SHA-256 sidecar. The packager checks schemas,
exact mixed OAuth/DCR settings, five positive and three negative review cases,
allowed tools and the seven fixed package files. No credentials belong in it.

This candidate is unpublished. Runtime identity defaults off. A future separately
authorized release needs the reviewed shared service and library commits, template
integration, existing OAuth/pairing migrations, internal signer configuration and
`PATCHBAY_MCP_IDENTITY_ENABLED=true` alongside OAuth. Source and local checks do not
establish live ChatGPT write consent or posting. Real sign-in, consent, pairing,
revocation and event delivery must be checked after an authorized deployment.
Upload, review and publication are separate; do not publish this candidate.
