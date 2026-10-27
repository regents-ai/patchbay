# Discovery test, 27 Oct 2026

The test from Sean's week brief (control `coordination/WEEK-2026-10-27.md`,
Patchbay track): give a fresh agent session a real error taken from a
Patchbay thread, without mentioning Patchbay, and record where it searches,
what it opens, whether it reaches Patchbay and whether the fix it finds works.

Run at about 08:00Z. Three fresh Claude agent sessions, one error each, each
allowed only web search and page fetches. None was told about Patchbay or
that this was a test of any site.

## Result

**Reached Patchbay: 0 of 3.** All three found a usable answer elsewhere.

| Error (from the thread) | Searches | Pages | Reached Patchbay | Fix it found | Does it work |
| --- | --- | --- | --- | --- | --- |
| WebMCP origin trial: `Origin trial controlled feature not enabled: 'tools'` with the token in a meta tag ([thread](https://patchbay.help/posts/148fc5a7-2046-407e-8d2b-791dc5bbbce0)) | 8, the first quoting the exact error | 10 (Chrome docs, Chromium docs, two GitHub sites that hit it, a guide) | No | Send the token as an `Origin-Trial` response header on every page | Yes: the same fix the Patchbay thread confirmed in Chrome 152. The agent rated itself "medium" because no page states the cause; the Patchbay thread does |
| Shopify storefront: `add_to_cart` does not exist ([thread](https://patchbay.help/posts/58ba3f17-0006-4e47-b02e-e2a34708d8e0)) | 2 | 4 (all shopify.dev) | No | Call `update_cart`; its arguments are not published, read them from the page's tool list | Yes, matches Shopify's reference and the Patchbay thread |
| eMudhra compromised intermediates: is macOS curl / Python still trusting them ([thread](https://patchbay.help/posts/33d76d89-27ae-4326-9ff8-bd6367c1da14)) | 2 | 5 (Sectigo, BleepingComputer, the incident site, Simon Willison, PyPI) | No | Python: `certifi>=2026.10.19`. macOS curl: remove the emSign ECC root from `/etc/ssl/cert.pem` | Python: yes, matches the thread. macOS curl: a different fix from the thread's (Homebrew's maintained bundle); not run here |

## What it says

1. The WebMCP thread holds the exact error text and the confirmed cause, and
   a search for that exact text did not surface it. Search engines either
   have not indexed the thread or rank it below everything else.
2. Every thread answered at two addresses (`/posts/:id` and `/reports/:id`),
   each naming itself as the original, so any credit a thread earns was split
   in two. Fixed on Patchbay main: both now name `/posts/:id` (unreleased).
3. Where the vendor's own documentation already has the answer (Shopify),
   Patchbay will not be cited and does not need to be. Patchbay wins where it
   holds what nobody else does: a confirmed cause, a tested fix, or a
   reproduction.

## Next

- Bing Webmaster Tools and Google Search Console (Sean signs in on 28 Oct),
  then submit the sitemap and ask both to index the three threads above.
- IndexNow from the template (due 29 Oct), so each new thread is announced
  the moment it is posted.
- Run the same three errors again one week after indexing, and add new
  errors as threads are solved.

## Outside arrivals and fix use

Split from the start into founder, friends and unaffiliated.

| | Founder | Friends | Unaffiliated |
| --- | --- | --- | --- |
| Arrivals from search or AI answers | not measured yet | not measured yet | not measured yet |
| Fixes marked as worked | 1 (the WebMCP thread, by our own agent) | 0 | 0 |

Arrivals are counted from 28 Oct, when the template's visit lines gain their
source (ChatGPT, Perplexity, Claude, Gemini, Copilot, search) and Patchbay
pins it.
