# One form on the home page, sites as domains — plan (2026-09-28)

Founder asks (2026-09-28), shipped as one release on top of `931cc77`:

- The home hero is one form: what you are trying to do, the site, the site's WebMCP
  tools (pick up to 5), an optional **Add details** (what happened, up to 3 pictures,
  kind of post, tags), and two buttons: **Jev** (free / sign in / fee, as today) and
  **Post to the forum**. The popular sites stay under it.
- `/ask` and the lower "Stuck on a site's tools?" box are removed. "Ask about this
  site/tool" links open the home form with the site (and tool) filled in.
- A labelled **Search** field at the top of the discussions section looks up as you
  type: the list narrows and matching sites and tools show above it.
- **Sites become domains** (shopify.com, openai.com). A tool still records the exact
  address it was seen at, and the skills and instructions ask agents to share the
  exact URL where they used a tool.
- **Posts carry 0 to 5 tools**, shown on the post and filterable by tool.
- Pictures go on forum posts only.

## Decisions taken here (engineering)

1. The registrable domain comes from the Public Suffix List (`domainatrex`, bundled
   list, no fetch at build). A host that is itself a public suffix (`vercel.app`) is
   refused; `someone.vercel.app` is its own site.
2. `forum_sites.origin` keeps its name and now holds the domain. All 11 production
   sites are already domains (checked 2026-09-28), so no merge migration; check
   again right before release.
3. `forum_tools.address`: the exact https URL the tool was last seen at.
4. Posts: `tool_names` (array, 0–5, tool-name shape) replaces `subject_tool_name`,
   backfilled from it or from the observed tool. Agent field: `tools`.
5. Posts: optional `page_url`, the exact https URL where the tool was used.
6. Pictures: `forum_post_pictures` (binary, PNG/JPEG/WebP by magic bytes, ≤3 MB,
   ≤3 per post), served same-origin. Page form only; signed-in people only.
7. The post preview (private-details check) runs in place on the home page, so
   chosen pictures stay chosen; Post then sends the form.
8. Home filters gain `tool`; `site`/`tool`/`goal` query values also fill the form.

## Lanes

- **A — domains** (separate worktree): 1–3 plus agent contract wording and skills.
- **B — form, posts, search** (this worktree): 4–8, `/ask` removal, contracts.

Integration, checks and one browser pass happen here; release waits on Sean's go
(the paid fix and the forum write path both change).
