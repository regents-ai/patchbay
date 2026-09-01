# Local WebMCP and security notes

These notes describe the browser requirements used by this prototype. WebMCP
is experimental and the API may change.

## Chrome requirements (checked 2026-09-01)

Chrome's current WebMCP documentation describes WebMCP as a proposed standard.
The WebMCP origin trial is available from Chrome 149. For local development,
Chrome documents a flag that avoids needing an origin-trial token:

1. Open `chrome://flags/#enable-webmcp-testing`.
2. Set **WebMCP** to **Enabled**.
3. Relaunch Chrome and open the local room at <http://localhost:4000/webmcp/rooms/skill-uplift>.

For a real origin-trial deployment, request a token for the exact origin and
deliver it as an `Origin-Trial` response header or HTML meta tag. Do not put a
token in this repository. The token is not needed for the local flag path.

WebMCP is available only in origin-isolated documents. Do not opt the page out
with `document.domain` or an `Origin-Agent-Cluster: ?0` response header. The
`tools` Permissions Policy defaults to `self`, which covers a top-level page
and same-origin contexts. A cross-origin iframe needs `allow="tools"` and
should be used only when that origin is trusted.

Patchbay feature-detects `document.modelContext` and keeps the older
`navigator.modelContext` surface as compatibility for early origin-trial
builds. If neither surface exists, the hook reports WebMCP unavailable and
leaves the room's human controls usable.

Authoritative references:

- [WebMCP overview and local flag](https://developer.chrome.com/docs/ai/webmcp) (Chrome for Developers, updated 2026-08-07)
- [WebMCP origin trial announcement](https://developer.chrome.com/blog/ai-webmcp-origin-trial) (Chrome for Developers, 2026-06-09)
- [WebMCP tool security](https://developer.chrome.com/docs/ai/webmcp/secure-tools) (Chrome for Developers, updated 2026-07-01)

## What Patchbay protects

- The server owns the room, current revision, generation, contract digest and
  verification result. Browser observations are evidence inputs, not proof by
  themselves.
- Incoming room, browser-session, revision, generation, and contract values
  are checked against server-owned records. Foreign registry entries and stale
  revisions are rejected.
- The seeded v1 handler is allowed to report success without applying its
  candidate. Patchbay records the raw response separately from the effective
  visible result and fails closed when the Candidate editor is empty.
- Repair plans are a small allowlisted DSL. A deterministic canary must pass
  before a proposal can be approved. Only the named human LiveView action can
  approve and publish a replacement.
- Tool descriptions and outputs are bounded. User-authored Skill text,
  external model output, and browser observations are treated as untrusted
  data. No WebMCP tool is exposed to another origin by this demo.
- The fallback is explicitly opt-in and visibly labeled. It is a checked-in
  fixture for demonstration, not an evaluation of model quality or task
  success.

Never commit API keys, origin-trial tokens, or production data. This repository
does not include a live deployment endpoint or recorded video.
