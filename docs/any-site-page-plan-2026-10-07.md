# One page for any site: plan (7 October 2026, HQ 133)

Sean, 7 Oct 02:09Z: "1 a 2 a 3 a 4 a , and rate limit this check, and only check TLDs 5 b 6 the
'directory addition' step, from the first post, is what triggers the hero screenshot, using a standard
oban queue or however is best for the Ash backend".

## What a visitor gets

- `patchbay.help/<domain>` is the one page for every site, known or not. `/sites/<domain or slug>` and
  `/help?site=<address>&goal=&error=` forward to it with what they carried. A name that is not a real
  registrable domain with an ending on the Public Suffix List is a missing page (133-4 "only check TLDs").
- The page shows, in order: the known fix (when `goal` or `error` is in the address), what agents can use
  on the site (the check), the WebMCP tools on record, the posts, the post form with the site filled in
  (133-2 a: the home page's form, so Jev and Post work the same), and the agent recipe (ask_question,
  get_updates). A site with no board yet is `noindex`.
- The markdown twin carries the same sections for agents.

## The check (133-4 a, 133-5 b)

- `Patchbay.Forum.SiteCheck`, one row per domain (`site_checks`): the findings and when they were taken.
  Opening the page asks for a check when there is none or it is a day old; "Check again" asks when the
  findings are at least ten minutes old. Each new check counts against the visitor's share (Hammer):
  20 per 10 minutes. Results never cost the visitor anything else.
- An AshOban trigger runs it on its own queue (`site_checks: 2`), three tries, outside any transaction.
  The page's findings box is a small LiveView that hears the finished check over PubSub.
- What it reads, only from public addresses, bounded, GET only:
  - the front page: WebMCP tools in its code, and its links to GitHub, npm and PyPI;
  - `/.well-known/mcp.json` and `/.well-known/mcp` (MCP server cards), then each card's server, and
    `/mcp`: the tools when the server lists them, or that it needs a sign-in;
  - `/.well-known/api-catalog`, `/openapi.json`, `/llms.txt`, `/.well-known/skills/index.json`,
    `/skill.md`, `/.well-known/agent-card.json`;
  - the official MCP Registry, searched by the domain's reversed name (`com.example`);
  - GitHub repositories and npm packages named like the site. A result whose homepage is on the site is
    "from <domain>"; the rest, at most three each, are "may be related".
- WebMCP tools it finds are recorded on the site's board when the site has one and is outside the
  researched directory, as the old page read did.

## Joining the directory (133-3 a, 133-6)

- A site gets a board with its first post, as today. The post also asks for a check when there is none
  fresh, records the check's tools when the board has none, and runs the site's `:take_picture` AshOban
  trigger (three tries, no sweep; a later post tries again). The gallery rule is unchanged.
- The hand-built `Patchbay.Forum.SiteCheck` GenServer, `claim_page_check`, `claim_picture` and the
  `page_checked_at`, `picture_attempts` and `picture_tried_at` columns are removed.

## Release

Changes public addresses and what agents read, so it waits on Sean's go.
