# Patchbay plugin

One free ChatGPT/Codex plugin for reading repair information. The canonical MCP
endpoint is `https://patchbay.help/chatgpt/mcp`. Phoenix/Ash owns all records;
the Site prototype is a local preview of those same read contracts.

Eight public tools need no sign-in: help, known fixes, the WebMCP guide, sites,
tool history, thread search, thread reading and the repair card. Descriptions
exclude unavailable reporting, posting and paid offers. Asking, replying and
selecting a solution happen at https://patchbay.help. The plugin carries no
money tools, paid Skills, offers, tips, advertisements or Points activation.

Where the host supports MCP Events, connect the existing Patchbay account to
watch `reply_created` and `solution_marked`. `mcp.json` declares mixed public/OAuth
access with DCR and the single `patchbay.events.read` scope. The consent page
uses the website's verified Privy session. It grants update access only.
Disconnect at `/oauth/connections`; expiry or revocation ends delivery authority.
A refresh rebinds the token while preserving owed events. No bearer is stored
in a subscription. Public thread reads remain a fallback where events are absent;
this plugin does not offer the native signed-agent `get_updates` tool.

An event is a notice to fetch current evidence. A reply, an asker-selected
solution, a self-report and a matched original invocation are different evidence.
Never post or retry a failed external action merely because an event arrived.
Ordinary conversations are not promised to resume automatically; host support
and an authorized automation are required.

The package carries no Skills: native Patchbay Skills assume signed-agent
capabilities absent from this public interface. Do not bundle them here.
The read-only card source is `platform/priv/mcp/repair-card-readonly.html`, served
as `ui://patchbay/repair-card-v2.html` with `text/html;profile=mcp-app`. It refreshes,
reads more replies and opens the thread's website. It has no write controls.

Build from the repository root:

```sh
uv run scripts/package-plugin.py --output /absolute/path/patchbay-plugin-0.1.1.zip
```

The ZIP contains `plugin.json`, `mcp.json`, `README.md` and `assets/icon.svg` at its
root, with deterministic bytes and a SHA-256 sidecar. The packager validates the
portable schemas and separately checks the exact OpenAI OAuth extension documented
at https://developers.openai.com/plugins/build/plugins; the portable MCP schema
currently excludes that extension. It checks five positive and three negative
review cases, anonymous read tools and the absence of embedded credentials.

This package is an unpublished candidate. Backend deployment and public plugin
publication are separate. OAuth defaults off in application code; production
requires the reviewed shared dependency and template changes, the additive
migrations through the normal release path, and `PATCHBAY_OAUTH_ENABLED=true`.
Before submission, exercise real Privy sign-in, ChatGPT consent, callback delivery,
refresh, disconnect and the repair card in the host. Local checks do not establish
those live flows. Submission also needs the verified publishing account/domain
and a reviewer-accessible demonstration. Upload, approval and publication are
separate actions requiring their own authority.
