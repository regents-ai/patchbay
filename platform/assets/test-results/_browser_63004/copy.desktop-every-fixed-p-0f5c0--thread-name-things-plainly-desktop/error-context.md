# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: copy.desktop.spec.ts >> every fixed page, a site, a tool and a thread name things plainly
- Location: test/browser/copy.desktop.spec.ts:67:1

# Error details

```
Test timeout of 180000ms exceeded.
```

```
Error: page.goto: Test timeout of 180000ms exceeded.
Call log:
  - navigating to "http://127.0.0.1:63004/google.com", waiting until "load"

```

# Page snapshot

```yaml
- generic [active] [ref=f37e1]:
  - link "Skip to the main content" [ref=f37e2] [cursor=pointer]:
    - /url: "#pb-content"
  - generic [ref=f37e3]:
    - banner [ref=f37e6]:
      - link "Patchbay home" [ref=f37e7] [cursor=pointer]:
        - /url: /
        - text: Patchbay
      - generic [ref=f37e25]:
        - button "Search" [ref=f37e26]: Search Ctrl K
        - navigation "Patchbay" [ref=f37e29]:
          - link "Questions" [ref=f37e30] [cursor=pointer]:
            - /url: /
          - link "Sites" [ref=f37e31] [cursor=pointer]:
            - /url: /sites
          - link "Offers" [ref=f37e32] [cursor=pointer]:
            - /url: /offers
        - link "Ask a question" [ref=f37e33] [cursor=pointer]:
          - /url: /?ask=1#pb-hero
        - button "Menu" [ref=f37e36]
      - generic [ref=f37e37]:
        - button "Dark theme on. Switch to light theme. Light theme on. Switch to dark theme." [ref=f37e38]
        - button "Sign in" [ref=f37e40]
    - main [ref=f37e45]:
      - generic [ref=f37e47]:
        - generic [ref=f37e66]:
          - paragraph [ref=f37e67]:
            - link "ALL SITES" [ref=f37e68] [cursor=pointer]:
              - /url: /sites
            - text: / SITE
          - heading "Chrome" [level=1] [ref=f37e69]
        - generic [ref=f37e70]: google.com
      - generic [ref=f37e71]:
        - generic [ref=f37e72]:
          - generic [ref=f37e73]:
            - paragraph [ref=f37e74]: QUESTIONS
            - heading "Posts" [level=2] [ref=f37e75]
          - link "Post about google.com" [ref=f37e76] [cursor=pointer]:
            - /url: "#pb-site-post"
        - generic [ref=f37e77]:
          - paragraph [ref=f37e78]: Nothing has been asked or reported about this site yet.
          - link "Ask a question" [ref=f37e80] [cursor=pointer]:
            - /url: "#pb-site-post"
      - region [ref=f37e81]:
        - heading "Status" [level=2] [ref=f37e82]
        - paragraph [ref=f37e83]: 0 tools
        - generic [ref=f37e84]:
          - generic [ref=f37e85]:
            - heading [level=3] [ref=f37e86]:
              - link "Solved 0" [ref=f37e87] [cursor=pointer]:
                - /url: /?site=google.com&scope=solved
            - paragraph [ref=f37e88]: Nothing solved here yet.
          - generic [ref=f37e89]:
            - heading [level=3] [ref=f37e90]:
              - link "Still open 0" [ref=f37e91] [cursor=pointer]:
                - /url: /?site=google.com&scope=unanswered
            - paragraph [ref=f37e92]: No open questions.
      - region "About" [ref=f37e93]:
        - generic [ref=f37e94]: C
        - generic [ref=f37e95]:
          - paragraph [ref=f37e96]: Browser support · google.com
          - paragraph [ref=f37e97]: A browser that implements WebMCP so agents can call tools on the pages it loads.
          - generic [ref=f37e98]:
            - term [ref=f37e99]: Inventory
            - definition [ref=f37e100]: No public tool inventory
            - term [ref=f37e101]: Support status
            - definition [ref=f37e102]: Experimental
            - term [ref=f37e103]: Source
            - definition [ref=f37e104]:
              - link "Chrome WebMCP documentation (origin trial from Chrome 149)" [ref=f37e105] [cursor=pointer]:
                - /url: https://developer.chrome.com/docs/ai/webmcp
            - term [ref=f37e106]: Checked
            - definition [ref=f37e107]:
              - time [ref=f37e108]: 11 Sep 2026
        - paragraph [ref=f37e110]:
          - button "Refresh this site" [disabled] [ref=f37e111]
          - status [ref=f37e112]: Taking a new picture and checking its tools…
      - region [ref=f37e114]:
        - generic [ref=f37e115]:
          - button "Copy for your agent Copied Couldn't copy" [ref=f37e116]
          - status
        - group [ref=f37e119]:
          - generic "For agents Looking for WebMCP tools… View more View less" [ref=f37e120]:
            - generic [ref=f37e121]:
              - heading "For agents" [level=2] [ref=f37e122]
              - text: Looking for WebMCP tools…
            - generic [ref=f37e123]: View more View less
    - contentinfo [ref=f37e126]:
      - generic [ref=f37e127]:
        - link "Patchbay on X" [ref=f37e128] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=f37e131] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=f37e134]:
        - link "Buy $REGENT" [ref=f37e135] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=f37e136] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=f37e137] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=f37e138]
        - link "Contact" [ref=f37e139] [cursor=pointer]:
          - /url: /contact
        - generic [ref=f37e140]:
          - link "Privacy policy" [ref=f37e141] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=f37e142] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=f37e143]: © 2026 Regents Labs
```

# Test source

```ts
  1  | import type {Page} from "@playwright/test"
  2  | import {expect, signedIn, test} from "./support/test"
  3  | 
  4  | // Patchbay's own words never open a heading, label, tab, link, button, table head,
  5  | // summary, page title or description with who, what, where, why or when; that reads
  6  | // as AI writing (founder, 28 Oct 2026). Headings, labels, legends and tabs are one or
  7  | // two words. Run at 1280 over every fixed page the sitemap lists, one site, one tool
  8  | // and one thread, and the signed-in pages. Writing by strangers and by the blog's
  9  | // authors is theirs: a post's or reply's words, a thread's title and an article.
  10 | //
  11 | // Left out until their owners change them, each named in the hand-off:
  12 | // - /privacy and /terms, which are versioned and change only on Sean's go;
  13 | // - the blog's index heading, which design-system draws for every Regent site.
  14 | // An incident's title and a changelog entry's are their articles' titles, as written.
  15 | const skippedPages = ["/privacy", "/terms"]
  16 | const content =
  17 |   ".rg-discussion__body, .rg-discussion__title, .rg-blog, .pb-incident-head h1, .pb-changelog__release"
  18 | 
  19 | const wWord = /^\s*(who|what|where|why|when)\b/i
  20 | 
  21 | async function copyProblems(page: Page) {
  22 |   return page.evaluate(
  23 |     ({content, wWord}) => {
  24 |       const opening = new RegExp(wWord, "i")
  25 |       const problems: string[] = []
  26 |       const words = (element: Element) => {
  27 |         const copy = element.cloneNode(true) as Element
  28 |         copy.querySelectorAll("[aria-hidden=true], select, .visually-hidden:not(label)").forEach(part => part.remove())
  29 |         return (copy.textContent ?? "").replace(/\s+/g, " ").replace(/\s*\(?\d[\d/,]*\)?\s*$/, "").trim()
  30 |       }
  31 | 
  32 |       const elements = "h1, h2, h3, h4, h5, h6, label, legend, summary, th, caption, dt, button, a, [role=tab]"
  33 |       for (const element of document.querySelectorAll(elements)) {
  34 |         if (element.closest(content)) continue
  35 |         const text = words(element)
  36 |         if (!text) continue
  37 |         if (opening.test(text)) problems.push(`${element.tagName.toLowerCase()} opens "${text.slice(0, 60)}"`)
  38 |         const named = element.matches("h1, h2, h3, h4, h5, h6, label, legend, [role=tab]")
  39 |         if (named && text.split(" ").length > 2) problems.push(`${element.tagName.toLowerCase()} "${text.slice(0, 60)}" is over two words`)
  40 |       }
  41 |       for (const element of document.querySelectorAll("[aria-label], [title], [placeholder]")) {
  42 |         if (element.closest(content)) continue
  43 |         for (const name of ["aria-label", "title", "placeholder"]) {
  44 |           const value = element.getAttribute(name)
  45 |           if (value && opening.test(value)) problems.push(`${name} opens "${value.slice(0, 60)}"`)
  46 |         }
  47 |       }
  48 |       const description = document.querySelector<HTMLMetaElement>("meta[name=description]")?.content ?? ""
  49 |       for (const [name, value] of [["title", document.title], ["description", description]])
  50 |         if (opening.test(value)) problems.push(`page ${name} opens "${value.slice(0, 60)}"`)
  51 |       return problems
  52 |     },
  53 |     {content, wWord: wWord.source},
  54 |   )
  55 | }
  56 | 
  57 | // Every page is read before the check fails, so one run names every problem.
  58 | async function expectPlainCopy(page: Page, paths: string[]) {
  59 |   const problems: string[] = []
  60 |   for (const path of paths) {
> 61 |     expect((await page.goto(path))?.status(), path).toBe(200)
     |                        ^ Error: page.goto: Test timeout of 180000ms exceeded.
  62 |     for (const problem of await copyProblems(page)) problems.push(`${path}: ${problem}`)
  63 |   }
  64 |   expect(problems).toEqual([])
  65 | }
  66 | 
  67 | test("every fixed page, a site, a tool and a thread name things plainly", async ({page}) => {
  68 |   test.setTimeout(180_000)
  69 |   const sitemap = await (await page.request.get("/sitemap.xml")).text()
  70 |   const listed = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => new URL(match[1]).pathname)
  71 |   const site = listed.find(path => /^\/[a-z0-9-]+\.[a-z.]+$/.test(path))!
  72 |   const tool = listed.find(path => path.includes("/tools/"))!
  73 |   const thread = listed.find(path => path.startsWith("/posts/"))!
  74 |   const fixed = listed.filter(
  75 |     path => !/^\/(posts|blog\/|wallet-bench\/H)/.test(path) && !path.includes(".") && !skippedPages.includes(path),
  76 |   )
  77 |   expect(fixed.length).toBeGreaterThan(20)
  78 | 
  79 |   await expectPlainCopy(page, [...fixed, site, tool, thread, "/blog"])
  80 | })
  81 | 
  82 | test.describe("signed in", () => {
  83 |   test.use(signedIn)
  84 | 
  85 |   test("the account and Offers pages name things plainly", async ({page}) => {
  86 |     await expectPlainCopy(page, [
  87 |       "/account/inbox",
  88 |       "/account/profile",
  89 |       "/points",
  90 |       "/credits-help",
  91 |       "/offers/create",
  92 |       "/offers/active",
  93 |       "/offers/history",
  94 |     ])
  95 |   })
  96 | })
  97 | 
```