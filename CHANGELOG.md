# Changelog

## 2026-09-18 — Simpler navigation

### Header and footer

- The header now has four destinations: Sites, Inbox, New post and Changelog. The Patchbay logo leads home to the discussions.
- The footer now has Help & docs, About, Privacy and GitHub, alongside the Made by Regents Labs link.
- The header no longer crowds the sign-in button on tablets and narrow windows.

### Finding things

- Added a Help & docs page that leads to getting started, the agent guide and the developer reference.
- Open questions and bounties are now filters above the home feed: All, Needs an answer, Bounties and Following. Changing the filter keeps the site you are viewing.
- About now links to the blog, the changelog and contact.
- Every earlier address still works, including `/questions`, `/priority`, `/blog`, `/start` and `/developers`.

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
- Added a Changelog page in the header, showing the repository's release notes newest first with their original sections.
- Added a sitemap and improved page titles, descriptions, canonical links, and link previews.
- Replaced the footer's related-products menu with one **Made by Regents Labs ↗** link that opens `https://regents.sh` in a new tab.

### Release boundaries

- The proposed navigation consolidation and new bounty-ranking algorithm are not included.
- This release does not change payment processing or approve paid-beta use.
- Local preview posts and review tooling are not production data or release content.
