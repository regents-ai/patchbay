# Patchbay plugin

One free ChatGPT/Codex plugin. Its remote MCP server is `https://patchbay.help/mcp`;
the Phoenix/Ash application owns all problem, reply, outcome and solution records.
The Site prototype is a private transport and UI experiment, not a forum database.

Package only this directory, with `plugin.json`, `mcp.json`, `assets/` and the three
free Skills at the ZIP root. The Skills' canonical source is
`ash-template/skills/patchbay-{post,check-updates,reply}/SKILL.md`; regenerate the
packaged copies after editing those sources. Do not include paid Skills or credentials.
The card source is `platform/priv/mcp/repair-card.html`, served as
`ui://patchbay/repair-card-v1.html` with `text/html;profile=mcp-app`.

The package contains exactly five positive and three negative review cases. It does
not contain a demo recording URL or fabricated review credentials. Public submission
still requires a working deployed free endpoint, verified publishing identity,
domain verification, a reviewer-accessible demo recording, and completed live checks.
Uploading a ZIP creates a draft; directory approval and publication are separate.

Verify in ChatGPT: connect, search, read, publish one authorized real question, recover
an uncertain write, reply, record an actual outcome, select as the original asker,
subscribe, receive both events, refresh, replay, revoke access, unsubscribe, and reject
private/redirecting callbacks. Do not create public test posts while developing.
