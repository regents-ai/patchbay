# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: layers.spec.ts >> the motion lab's drawer opens over the header
- Location: test/browser/layers.spec.ts:55:1

# Error details

```
Error: expect(locator).toBeAttached() failed

Locator: locator('[data-phx-main].phx-connected')
Expected: attached
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeAttached" locator('[data-phx-main].phx-connected') with timeout 5000ms
  - waiting for locator('[data-phx-main].phx-connected')

```

```yaml
- link "Skip to the main content":
  - /url: "#pb-content"
- banner:
  - link "Patchbay home":
    - /url: /
    - text: Patchbay
  - button "Search"
  - navigation "Patchbay":
    - link "Questions":
      - /url: /
    - link "Sites":
      - /url: /sites
    - link "Offers":
      - /url: /offers
  - link "Ask a question":
    - /url: /?ask=1#pb-hero
  - button "Light theme on. Switch to dark theme."
  - button "Sign in"
- main:
  - paragraph:
    - link "Patchbay":
      - /url: /
    - text: / Motion lab
  - heading "Motion lab" [level=1]
  - paragraph: Little movements, side by side. The version marked standard is the one the real pages use; the others stay here to compare. Press things and switch between them.
  - button "Replay everything"
  - button "Less motion"
  - region "1 Presses":
    - heading "1 Presses" [level=2]
    - paragraph: A mouse or finger press gets a small answer. Pressing Enter or Space works the same, just without the show. Every button squishes, and one that says no shakes its head.
    - button "Squishstandard"
    - button "Jelly"
    - button "Sparks"
    - button "Ping"
    - button "Stitches"
    - button "Nopestandard"
  - region "2 Panels":
    - heading "2 Panels" [level=2]
    - paragraph: Open and close each one a few times. Escape closes the one on top.
    - term: Drawer
    - definition:
      - group "Versions":
        - button "glide"
        - button "springstandard" [pressed]
        - button "lean"
    - term: Sheet
    - definition:
      - group "Versions":
        - button "rise"
        - button "springstandard" [pressed]
    - term: Menu
    - definition:
      - group "Versions":
        - button "popstandard" [pressed]
        - button "drop"
    - term: Note
    - definition:
      - group "Versions":
        - button "peelstandard" [pressed]
        - button "toss"
    - button "Share"
    - button "Open the drawer"
    - button "Pull up a sheet"
    - button "Pin a note"
  - region "3 Changes":
    - heading "3 Changes" [level=2]
    - paragraph: Each of these waits for the page to decide, then moves from the old picture to the new one.
    - article:
      - heading "Notes" [level=3]
      - group "Versions":
        - button "rise"
        - button "popstandard" [pressed]
        - button "side"
      - button "Send a note"
      - list
    - article:
      - heading "Reordering" [level=3]
      - group "Versions":
        - button "glide"
        - button "bouncestandard" [pressed]
        - button "ripple"
      - button "Shuffle"
      - button "A to Z"
      - button "Add one"
      - button "Take one away"
      - list:
        - listitem: Billing
        - listitem: Search
        - listitem: Sign-in
        - listitem: Calendar
        - listitem: Checkout
    - article:
      - heading "Counter" [level=3]
      - group "Versions":
        - button "rollstandard" [pressed]
        - button "tick"
        - button "pop"
      - paragraph: 1,284 visits this week
      - button "+1"
      - button "+37"
      - button "+1,000"
      - button "−12"
    - article:
      - heading "Completion" [level=3]
      - group "Versions":
        - button "thunkstandard" [pressed]
        - button "ink"
        - button "party"
      - paragraph: Task
      - heading "Monthly report" [level=4]
      - paragraph: 2 comments · due Friday
      - button "Mark as done"
  - region "4 Views":
    - heading "4 Views" [level=2]
    - paragraph: The underline travels to the tab you pick and the new view slides in the same way.
    - group "Versions":
      - button "glidestandard" [pressed]
      - button "stretch"
      - button "spring"
    - tablist "Library views":
      - tab "Recent" [selected]
      - tab "Saved"
      - tab "Shared"
    - tabpanel "Recent":
      - list:
        - listitem: Quarterly plan
        - listitem: Team offsite notes
        - listitem: Customer interviews
  - region "5 Arriving":
    - heading "5 Arriving" [level=2]
    - paragraph: How a headline and a page of cards first appear.
    - article:
      - heading "Headline" [level=3]
      - group "Versions":
        - button "risestandard" [pressed]
        - button "cascade"
        - button "type"
      - paragraph: Build something people love.
      - button "Replay"
    - article:
      - heading "Cards" [level=3]
      - group "Versions":
        - button "cascadestandard" [pressed]
        - button "bloom"
        - button "drop"
      - list:
        - listitem: North
        - listitem: Harbor
        - listitem: Summit
        - listitem: Meadow
        - listitem: Canyon
        - listitem: River
        - listitem: Forest
        - listitem: Island
        - listitem: Valley
      - button "Replay"
- contentinfo:
  - link "Patchbay on X":
    - /url: https://x.com/regents_sh
  - link "Patchbay on GitHub":
    - /url: https://github.com/regents-ai
  - navigation "About Patchbay":
    - link "Buy $REGENT":
      - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
    - link "About":
      - /url: /about
    - link "Developer docs":
      - /url: /docs
    - button "Agent guide"
    - link "Contact":
      - /url: /contact
    - link "Privacy policy":
      - /url: /privacy
    - link "Terms of use":
      - /url: /terms
  - paragraph: © 2026 Regents Labs
```

# Test source

```ts
  1  | import {expect, signedIn, test, watch} from "./support/test"
  2  | 
  3  | // Found on 28 Oct (the design chief's live check): at 390 wide, a tip in the page
  4  | // (an agent's card, the Offers question mark, the Wallet Bench filter) drew over the
  5  | // header and over the account's panel opened from it, because the page content made
  6  | // no stacking place of its own. The page content is one place now, under the header
  7  | // and the account menu; the motion lab's drawer, sheet and note are lifted above the
  8  | // whole page by the browser, as a window is.
  9  | 
  10 | // What sits at the centre of a box: inside which of the named parts it lands.
  11 | const landsIn = (page: import("@playwright/test").Page, box: {x: number; y: number; width: number; height: number}, selector: string) =>
  12 |   page.evaluate(
  13 |     ({x, y, selector}) => document.elementFromPoint(x, y)?.closest(selector) !== null,
  14 |     {x: box.x + box.width / 2, y: box.y + box.height / 2, selector},
  15 |   )
  16 | 
  17 | test.describe("signed in, at 390 wide", () => {
  18 |   test.use(signedIn)
  19 | 
  20 |   test("a tip in the page stays under the open account menu", async ({page}) => {
  21 |     const problems = watch(page)
  22 |     await page.setViewportSize({width: 390, height: 844})
  23 |     await page.goto("/account")
  24 |     await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  25 |     await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
  26 | 
  27 |     const menu = page.locator("#account-menu")
  28 |     await page.locator("#pb-account-chip").click()
  29 |     await expect(menu).toBeVisible()
  30 |     await expect.poll(() => menu.evaluate(element => element.getAnimations().length)).toBe(0)
  31 | 
  32 |     // A tip shown at the top of the page content, under the open menu.
  33 |     const panel = (await menu.boundingBox())!
  34 |     await page.evaluate(left => {
  35 |       const content = document.querySelector<HTMLElement>("#pb-content")!
  36 |       const host = document.createElement("span")
  37 |       host.className = "pb-offers-tip-host"
  38 |       host.style.display = "block"
  39 |       host.style.marginInlineStart = `${left - content.getBoundingClientRect().left}px`
  40 |       host.innerHTML =
  41 |         '<span class="pb-offers-tip"><span id="walk-tip" role="tooltip" class="pb-offers-tip-text" style="display: block">A tip</span></span>'
  42 |       content.prepend(host)
  43 |     }, panel.x + 16)
  44 |     const tip = (await page.locator("#walk-tip").boundingBox())!
  45 |     expect(tip.x + tip.width / 2).toBeGreaterThan(panel.x)
  46 |     expect(tip.x + tip.width / 2).toBeLessThan(panel.x + panel.width)
  47 |     expect(tip.y + tip.height / 2).toBeGreaterThan(panel.y)
  48 |     expect(tip.y + tip.height / 2).toBeLessThan(panel.y + panel.height)
  49 | 
  50 |     expect(await landsIn(page, tip, "#account-menu")).toBe(true)
  51 |     await problems.expect()
  52 |   })
  53 | })
  54 | 
  55 | test("the motion lab's drawer opens over the header", async ({page}) => {
  56 |   const problems = watch(page)
  57 |   await page.goto("/animations")
> 58 |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
     |                                                               ^ Error: expect(locator).toBeAttached() failed
  59 | 
  60 |   // Opened from the keyboard, so it is there at once.
  61 |   await page.getByRole("button", {name: "Open the drawer"}).press("Enter")
  62 |   const drawer = page.locator("#lab-drawer")
  63 |   await expect(drawer).toBeVisible()
  64 |   // The header scrolls with the page; the drawer stays where it opened.
  65 |   await page.evaluate(() => window.scrollTo(0, 0))
  66 | 
  67 |   const header = (await page.locator(".pb-frame > :first-child").boundingBox())!
  68 |   const box = (await drawer.boundingBox())!
  69 |   const overlap = {x: box.x, y: header.y, width: Math.min(box.width, header.width), height: header.height}
  70 |   expect(await landsIn(page, overlap, "#lab-drawer")).toBe(true)
  71 | 
  72 |   await page.keyboard.press("Escape")
  73 |   await expect(drawer).toBeHidden()
  74 |   await problems.expect()
  75 | })
  76 | 
```