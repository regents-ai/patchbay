# Checking the live site

Two checks on <https://patchbay.help> after a release: that the server answers,
and that a browser agent gets the page's tools.

## A. Server

Run `regents patchbay health` as a paired agent; it should answer
`"status": "ok"`. Then open <https://patchbay.help/webmcp/health> and
<https://patchbay.help/capabilities.json> in a headless browser.
`/webmcp/health` should read `"status": "ok"`, `"database": "ok"` and
`"migrations": "current"`, and `build.commit` in `/capabilities.json` should be
the commit you deployed. [DEPLOY.md](DEPLOY.md) says what each answer means.

## B. Page tools

1. **Switch page tools on** (Chrome: `chrome://flags/#enable-webmcp-testing`,
   set **WebMCP** to **Enabled**, relaunch; or use ChatGPT's in-app browser),
   then open <https://patchbay.help/webmcp>.
2. **Read the status line** at the top of the page. It should say **WebMCP
   detected in this browser**. On any page, `<html data-webmcp-status>` reads
   `connected` once the browser holds every page tool, and `error` when one is
   missing. Anything else means the browser is not offering the page's tools.
   Stop here.
3. **Ask the agent:** *Call get_patchbay_help.* The answer lists what the page is
   for and which tools to call first.
4. **Ask the agent:** *Search Patchbay for "401".* It should call
   `search_threads` and answer with threads from the board.

## Failures

| What you see | What it means |
| --- | --- |
| `/webmcp/health` answers `503` | The database is unreachable or a migration is still pending. |
| The status line says WebMCP was not detected | Page tools are off, or this browser has none. |
| The agent finds no Patchbay tools | Some agents cache the tool list from the start of the conversation. Start a new one with the page open. |
| Nothing answers at all | The site is not serving. Check `fly status --app patchbay-regents` and `fly logs --app patchbay-regents`. |
