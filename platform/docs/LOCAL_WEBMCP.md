# Local WebMCP and security notes

These notes describe the browser requirements used by this prototype. WebMCP
is experimental and the API may change.

## ChatGPT's in-app browser

The in-app browser in ChatGPT offers a page's WebMCP tools to the assistant
without any flag or token. Open Patchbay there, keep the chat and the page both
in view, and follow [JUDGES.md](JUDGES.md).

## Chrome requirements (checked 2026-10-29)

Chrome's current WebMCP documentation describes WebMCP as a proposed standard.
The WebMCP origin trial runs from Chrome 149. For local development, Chrome
documents a flag that needs no origin-trial token:

1. Open `chrome://flags/#enable-webmcp-testing`.
2. Set **WebMCP** to **Enabled**.
3. Relaunch Chrome and open Patchbay, the published site or the local one at
   <http://localhost:4000/>. Every page registers the site's tools.

A headless Chromium started by Playwright takes the same switch as
`--enable-features=WebMCPTesting`; the browser walk's WebMCP step
(`assets/test/browser/webmcp.spec.ts`) starts its Chromium that way.

On https://patchbay.help the origin-trial token does the same for visitors.
It is a public token, tied to that one host, and it expires on 17 November
2026. It lives in `PatchbayWeb.Plugs.BrowserPolicy`
(`lib/patchbay_web/plugs/browser_policy.ex`), which sends it as an
`Origin-Trial` response header beside `Permissions-Policy: tools=(self)` on
every page. Renew it there, with its new expiry in the comment beside it,
before it runs out.

WebMCP is available only in origin-isolated documents. Do not opt the page out
with `document.domain` or an `Origin-Agent-Cluster: ?0` response header. The
`tools` Permissions Policy is `self`, which covers a top-level page and
same-origin contexts. A cross-origin iframe needs `allow="tools"` and should be
used only when that origin is trusted.

Patchbay reads `document.modelContext` and nothing else. When a browser has no
WebMCP, the page registers nothing, its `<html>` element carries
`data-webmcp-status="unsupported"`, and every page still works by hand. Once
the browser's `getTools()` lists every page tool, the attribute reads
`connected`; when registration fails or a tool is missing, `error`.

The old shared demo room at `/webmcp/rooms/skill-uplift` is retired and now
leads to `/start`. Rooms that already exist still open at
`/webmcp/rooms/<slug>`.

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

Never commit API keys or production data. The origin-trial token is the one
public exception, kept in `PatchbayWeb.Plugs.BrowserPolicy`.
