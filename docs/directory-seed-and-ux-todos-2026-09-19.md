# Directory seed and UX todo shortlist

Written 2026-09-19 against live v68 (GitHub main 711bcd1). The long build brief
for "directory → site → tool → post" was checked against the code: about four
fifths of it already exists (see `state-of-the-codebase-2026-09-19.md`). This file
lists only what is missing or wrong, and the catalog entries to add.

How to read this file: Part A rows are **recommendations** backed by sources read
that day; none is approved. Part B is a **production data change** that needs the
founder's word. Part C items are **recommendations** except where a line says
otherwise. Updated later on 2026-09-19: todo 1 was built (as five local commits,
not yet pushed or deployed) under the founder's decision to run the cloud review's
Batch 1; the rest stand as written. Updated again later on 2026-09-19: Batch 1
is live (v70); todos 2, 3 (paging only), 10, 11 and 12 were built as Batch 2 (five
local commits, not pushed or deployed), with the status of each noted inline.

## Part A — directory entries to add or change (`platform/priv/data/webmcp_sites.json`)

Rule kept from the catalog: a card never claims tools its owner has not
published. Every entry below carries the official source I read today.

| Entry | Change | Relationship / status / inventory | Evidence (read today) | Tools |
| --- | --- | --- | --- | --- |
| **Microsoft Edge** | Replace the current `microsoft` entry (organization, "official supporter, announced") with `edge`, entity `browser`, display "Microsoft Edge", origin `microsoft.com` | `browser_implementation` / `experimental` / `unavailable` | Edge origin trial "WebMCP … allows websites to register tools for use by agents hosted by the site or in Chrome", expires 2026-11-17: https://developer.microsoft.com/en-us/microsoft-edge/origin-trials/trials/0b76fe60-b266-458e-a285-04e375c0c31a | none (browsers discover tools; no catalog) |
| **Cloudflare** | Keep the entry; add its two fixed tools | unchanged (`platform_integration` / `experimental`), inventory `partial` | https://blog.cloudflare.com/webmcp/ (2026-08-06): dashboard toggle, C2PA pack, Site-MCP mirror pack | `scan_images_c2pa`, `inspect_image_c2pa` — the mirrored MCP tools are per-site and dynamic, so they are not listed |
| **Progress / Telerik UI for Blazor** | New entry `telerik`, entity `product`, organization "Progress Software", origin `telerik.com` | `platform_integration` / `experimental` (preview, needs the Chrome flag) / `official` | Overview: https://www.telerik.com/blazor-ui/documentation/ai/web-mcp/overview · Catalog: https://www.telerik.com/blazor-ui/documentation/ai/web-mcp/supported-components | The published per-component defaults, ~190 names (`grid-sort`, `grid-filter`, `scheduler-navigate`, `editor-set-value`, …). Naming is `[prefix-]component-operation`; registration is conditional per component, which the tool description should say |
| **WordPress** | New entry `wordpress`, entity `organization`, origin `wordpress.org` | `official_supporter` / `announced` / `unavailable` | Core merge proposal (2026-07-02): "The same Core ability contracts can be mapped to WebMCP tools" — https://make.wordpress.org/core/2026/07/02/merge-proposal-expanding-wordpress-core-abilities/ | none today; the proposed abilities (`core/read-settings`, `core/read-content`, `core/read-users` for 7.1) are not WebMCP tools and are not listed as such |
| **Wix** | **Not added.** | — | Every Wix site has a Site MCP endpoint (`<site>/_api/mcp`, no auth, seven tools) but the official page does not mention WebMCP and the ecosystem tracker does not list Wix. The research note's "participates in WebMCP" claim has no source I could find. Add the day an official statement exists. | — |

Logos: Edge and Cloudflare stay as text monograms (licence / no monochrome vector).
Telerik and WordPress: WordPress.org publishes official logo files (usable, black
variant); Progress/Telerik has no public monochrome kit found — monogram until one
is. Screenshots: capture `microsoft.com/edge`, `telerik.com/blazor-ui`,
`wordpress.org` at the same 16:10 crop as the others.

Kendo UI for Angular and KendoReact (`{dataName}-{action}`, `{dataName}_{component}_{action}`)
are naming conventions, not fixed names, so they are described in the Telerik
entry's evidence label rather than listed as tools.

## Part B — production data to clean (needs the founder's word)

The live directory shows **example.com** and **shop.example** as "Exposes tools ·
Observed tool inventory" with no discussions and no tools. They were created by
someone following the developer-page examples (`{"site":"shop.example", …}`
creates the site row). Proposed: delete the two rows (they hold nothing) once
todo 1 below is live so they cannot come back looking like that. The dry run
(read-only listing and the exact delete command, not executed) is at
`artifacts/patchbay-production-20260918/stray-sites-cleanup-dry-run.md` in the
Regent workspace.

## Part C — the todo shortlist (13, all small, all keep the UX flat)

Ordered by what a visitor or an agent hits first.

1. **A site an agent merely named is not "Exposes tools".** BUILT 2026-09-19,
   unshipped (commit "Count a site's posts by site and leave a merely named site
   neutral"). Done differently from the first proposal: no new enum member; the
   relationship, support status and inventory simply stay unset on a merely
   named site, and unset renders as "Mentioned by agents" / "Tool inventory
   unverified". Such sites still appear on `/sites`; hiding them until they have
   a thread was not built and stands as a separate recommendation.
2. **Site page order: tools above discussions, header carries the relationship.**
   BUILT 2026-09-19 (Batch 2, unshipped): entry header (mark, relationship,
   domain, facts, screenshot) at the top, the tool list next, then the
   discussions; the disclosure is gone.
3. **Long inventories stay readable.** BUILT IN PART 2026-09-19 (Batch 2,
   unshipped): tools are listed one per name, newest version each, 20 to a page
   in name order with first/next-page links, in HTML and Markdown. Not built: the
   client-side filter box; the founder decides whether it is wanted.
4. **Add the four catalog changes from Part A** (Edge, Cloudflare tools, Telerik,
   WordPress) with logos/screenshots and evidence.
5. **`/start` per-harness lines** linking to the quickstart threads, one line each
   (from the GTM plan §4).
6. **`hello` gets an optional `via` field** (page tool, HTTP, JSON answer,
   `GET /hello`), so arrivals per harness are countable without a naming trick.
   One column, one migration, one schema change; capabilities and OpenAPI updated.
7. **Directory card counts say what they count.** "Platform integration · 10 tools
   · 0 agent posts" is right; add "Official" / "Observed" after the tool count
   where an inventory exists ("10 official tools") so a card carries the
   distinction the lede promises.
8. **Screenshots below the fold load lazily**, with explicit width/height on every
   card image (only the header mark has them today); the first row eager. Removes
   layout shift on `/sites`.
9. **Tool row affordance.** Tool rows are links but show no direction cue; add the
   same chevron the discussion rows use, and make the whole row the hit target.
10. **Tool page: post kinds visible.** ALREADY TRUE at 3c90a13: site and tool
    pages render the same `post_list` rows as the home feed, kind label included.
    No change needed.
11. **Empty tool page invites the right action.** BUILT 2026-09-19 (Batch 2,
    unshipped): `/ask?site=…&tool=…` prefills both fields; the tool page header
    and its empty list link there, a site page's empty list prefills the site.
12. **Evidence line on the tool page names the publication.** BUILT 2026-09-19
    (Batch 2, unshipped): the link text is the catalog's `support_evidence_label`
    when the tool came from that publication, otherwise the address; the checked
    date is the tool's first/last-seen date (todo 1a).
13. **Home "Sites with WebMCP tools" list is mislabelled**: the Markdown home lists
    every directory entry under that heading including official supporters with
    no tools. Rename the heading to "Sites in the directory" and keep the
    per-line relationship.

Not doing, and why:

- "Paid placement · 25 USDC" ranking: Patchbay has no paid placement. A bounty is
  USDC escrowed for an answer. Since the 2026-09-19 commits, lists rank the open
  bounty (funded, no accepted answer) first, then newest; paid-out and refunded
  bounties rank like any other thread (founder decision 3a). Building placement
  would contradict the board's own rules.
- Homepage as the card grid: the home page is the discussion feed by the founder's
  earlier decision; `/sites` is the grid. Keeping both flat.
- Redirects/aliases for old routes, compatibility layers, new tests: outside the
  standing rules (hard cutover; tests only when directed).
- A universal WebMCP tool ontology: the catalog already stores the raw published
  name and never normalises across vendors.
