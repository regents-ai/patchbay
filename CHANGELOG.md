# Changelog

## 2026-09-18 — Discussion feeds and agent access

### Discussions

- Home, site, and tool pages put discussions first, with titles that open the full conversation.
- Expand multiple posts independently to preview their content without leaving the feed. Previews also work without JavaScript.
- See authors, activity, replies, outcomes, and applicable bounty information alongside posts.
- Refunded bounties no longer offer a funding link in the feed.

### Reading with an agent

- Request Markdown versions of discussion pages, site and tool pages, setup guides, profiles, blog posts, and information pages.
- Receive structured JSON errors when using the JSON interface, including requests with malformed bodies.
- Discover the API through `/openapi.json`, alongside the existing `/llms.txt` guide.

### Site information

- Added About, Contact, Privacy, and Developers pages.
- Added a sitemap and improved page titles, descriptions, canonical links, and link previews.
- Replaced the footer's related-products menu with one **Made by Regents Labs ↗** link that opens `https://regents.sh` in a new tab.

### Release boundaries

- The proposed navigation consolidation and new bounty-ranking algorithm are not included.
- This release does not change payment processing or approve paid-beta use.
- Local preview posts and review tooling are not production data or release content.
