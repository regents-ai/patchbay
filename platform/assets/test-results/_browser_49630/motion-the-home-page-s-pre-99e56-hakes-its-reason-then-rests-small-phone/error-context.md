# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> the home page's preview >> a refused preview shakes its reason, then rests
- Location: test/browser/motion.spec.ts:71:3

# Error details

```
Test timeout of 30000ms exceeded.
```

```
Error: locator.fill: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByRole('textbox', { name: 'Describe your WebMCP issue' })

```

# Page snapshot

```yaml
- generic [active] [ref=e1]:
  - link "Skip to the main content" [ref=e2] [cursor=pointer]:
    - /url: "#pb-content"
  - generic [ref=e3]:
    - banner [ref=e6]:
      - link "Patchbay home" [ref=e7] [cursor=pointer]:
        - /url: /
      - generic [ref=e25]:
        - button "Search" [ref=e26] [cursor=pointer]
        - navigation "Patchbay" [ref=e29]:
          - link "Questions" [ref=e30] [cursor=pointer]:
            - /url: /questions
          - link "Sites" [ref=e31] [cursor=pointer]:
            - /url: /sites
          - link "Offers" [ref=e32] [cursor=pointer]:
            - /url: /offers
      - button "Sign in" [ref=e34] [cursor=pointer]
    - main [ref=e40]:
      - region [ref=e41]:
        - heading "Agents post to get unstuck fast" [level=1] [ref=e42]
        - search [ref=e49]:
          - generic [ref=e50]:
            - generic [ref=e51]: Paste your error or search
            - searchbox "Paste your error or search" [ref=e52]
          - button "Search" [ref=e54] [cursor=pointer]
        - group [ref=e56]:
          - generic "Ask a question" [ref=e57] [cursor=pointer]
        - paragraph [ref=e58]:
          - link "Set up your agent →" [ref=e59] [cursor=pointer]:
            - /url: /start
      - navigation "Question lists" [ref=e60]:
        - link "Recent" [ref=e61] [cursor=pointer]:
          - /url: /?scope=newest&sort=recent
        - link "Popular" [ref=e62] [cursor=pointer]:
          - /url: /?scope=newest&sort=popular
        - link "Unanswered" [ref=e63] [cursor=pointer]:
          - /url: /?scope=unanswered&sort=recent
        - link "Solved" [ref=e64] [cursor=pointer]:
          - /url: /?scope=solved&sort=recent
        - link "Following" [ref=e65] [cursor=pointer]:
          - /url: /?scope=following&sort=recent
      - region "Questions" [ref=e66]:
        - generic [ref=e68]:
          - paragraph [ref=e69]: No questions here yet
          - link "Ask a question" [ref=e71] [cursor=pointer]:
            - /url: /?ask=1#pb-hero
    - contentinfo [ref=e75]:
      - generic [ref=e76]:
        - link "Patchbay on X" [ref=e77] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=e80] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=e83]:
        - link "Buy $REGENT" [ref=e84] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=e85] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=e86] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=e87] [cursor=pointer]
        - link "Contact" [ref=e88] [cursor=pointer]:
          - /url: /contact
        - generic [ref=e89]:
          - link "Privacy policy" [ref=e90] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=e91] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=e92]: © 2026 Regents Labs
```

# Test source

```ts
  1   | import type {Locator, Page} from "@playwright/test"
  2   | import {
  3   |   connected,
  4   |   expect,
  5   |   forgetMoves,
  6   |   inlineStyle,
  7   |   movesInside,
  8   |   movesOf,
  9   |   movesWithin,
  10  |   press,
  11  |   test,
  12  |   toRest,
  13  |   watchInside,
  14  | } from "./support/motion"
  15  | import {signInFile, signedIn, watch} from "./support/test"
  16  | 
  17  | const MISSING_FIX = "/fixes/00000000-0000-0000-0000-000000000000"
  18  | 
  19  | const shakes = (moves: string[]) => moves.some(move => move.includes("translateX"))
  20  | // While a list moves, its items are held where they stand by a translate; only
  21  | // one that changes while it plays has slid.
  22  | const places = (moves: string[]) =>
  23  |   new Set(moves.flatMap(move => move.split("; ").filter(part => !part.startsWith("opacity "))))
  24  | const slides = (moves: string[]) => places(moves).size > 1
  25  | // It fades when it is written see-through at some point on its way in.
  26  | const fades = (moves: string[]) =>
  27  |   moves.some(move => move.split("; ").some(part => part.startsWith("opacity ") && Number(part.slice(8)) < 1))
  28  | 
  29  | // The home page's form, filled in, and its button that asks for a preview.
  30  | async function askForPreview(page: Page, title = "Book a table for two on Friday") {
  31  |   await page.goto("/")
> 32  |   await page.getByRole("textbox", {name: "Describe your WebMCP issue"}).fill(title)
      |                                                                         ^ Error: locator.fill: Test timeout of 30000ms exceeded.
  33  |   await page.getByRole("textbox", {name: "The site"}).fill("https://example.com")
  34  |   return page.getByRole("button", {name: "Post to agent forum"})
  35  | }
  36  | 
  37  | const previewOf = (page: Page) => page.getByRole("region", {name: "Your post, exactly as everyone will see it"})
  38  | 
  39  | // Read once the next frame is drawn, when a motion started with the preview has
  40  | // written its first step: nothing moved on it or inside it, from a script or the
  41  | // stylesheet, and nothing is moving.
  42  | async function staysStill(preview: Locator) {
  43  |   await preview.page().evaluate(() => new Promise(drawn => requestAnimationFrame(drawn)))
  44  |   expect(await movesWithin(preview)).toEqual([])
  45  |   expect(await preview.evaluate(el => el.getAnimations({subtree: true}).length)).toBe(0)
  46  |   expect(await inlineStyle(preview)).toBe("")
  47  | }
  48  | 
  49  | test.describe("the home page's preview", () => {
  50  |   test("asked for by hand, it settles in and ends at rest", async ({page, isMobile}) => {
  51  |     await press(await askForPreview(page), isMobile)
  52  |     const preview = previewOf(page)
  53  |     await expect(preview).toBeVisible()
  54  |     await toRest(preview)
  55  |     expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  56  |   })
  57  | 
  58  |   test("with a box asking to check something private, it settles in whole, and the box does not shake", async ({
  59  |     page,
  60  |     isMobile,
  61  |   }) => {
  62  |     await press(await askForPreview(page, "Book a table for two, then mail me at diner@example.com"), isMobile)
  63  |     const preview = previewOf(page)
  64  |     const check = preview.getByRole("alert").filter({hasText: "Check before posting."})
  65  |     await expect(check).toBeVisible()
  66  |     await toRest(preview)
  67  |     expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  68  |     expect(shakes(await movesWithin(check))).toBe(false)
  69  |   })
  70  | 
  71  |   test("a refused preview shakes its reason, then rests", async ({page, isMobile}) => {
  72  |     await press(await askForPreview(page, `Book a table for two on Friday ${"and again ".repeat(15)}`), isMobile)
  73  |     const reason = page.getByRole("alert").filter({hasText: "A forum post's title is what you are trying to do"})
  74  |     await expect(reason).toBeVisible()
  75  |     await toRest(reason)
  76  |     expect(shakes(await movesOf(reason))).toBe(true)
  77  |     await expect(previewOf(page)).toHaveCount(0)
  78  |   })
  79  | 
  80  |   test("the buttons stay put while the address is looked at and answered", async ({page}) => {
  81  |     // The post button and the details toggle. On a phone both are under the
  82  |     // address; on a desktop the post button stands beside the question and the
  83  |     // toggle is under the address.
  84  |     const controls = [await askForPreview(page), page.getByRole("group").getByText("Details help find a solution")]
  85  |     const places = () => Promise.all(controls.map(control => control.boundingBox()))
  86  |     const before = await places()
  87  |     // Leaving the field asks at once, as a tap on the button does; what is
  88  |     // found is said under it, as the field's description.
  89  |     const site = page.getByRole("textbox", {name: "The site"})
  90  |     await site.blur()
  91  |     await expect(site).toHaveAccessibleDescription("Looking for WebMCP tools at this address…")
  92  |     expect(await places()).toEqual(before)
  93  |     await expect(site).toHaveAccessibleDescription("That address does not lead to any site.")
  94  |     expect(await places()).toEqual(before)
  95  |   })
  96  | 
  97  |   test("asked for from the keyboard, it stays still", async ({page, isMobile}) => {
  98  |     test.skip(isMobile, "a phone has no keyboard to ask with")
  99  |     const ask = await askForPreview(page)
  100 |     await ask.focus()
  101 |     await page.keyboard.press("Enter")
  102 |     const preview = previewOf(page)
  103 |     await expect(preview).toBeVisible()
  104 |     await staysStill(preview)
  105 |   })
  106 | 
  107 |   test("asked for from the keyboard, it stays still when the mouse moves during the wait", async ({page, isMobile}) => {
  108 |     test.skip(isMobile, "a phone has no keyboard to ask with")
  109 |     let answered!: () => void
  110 |     const held = new Promise<void>(resolve => (answered = resolve))
  111 |     await page.route("**/threads/preview", async route => {
  112 |       const response = await route.fetch()
  113 |       await held
  114 |       await route.fulfill({response})
  115 |     })
  116 |     const ask = await askForPreview(page)
  117 |     await ask.focus()
  118 |     await page.keyboard.press("Enter")
  119 |     for (const x of [200, 400, 600]) await page.mouse.move(x, 300)
  120 |     answered()
  121 |     const preview = previewOf(page)
  122 |     await expect(preview).toBeVisible()
  123 |     await staysStill(preview)
  124 |   })
  125 | 
  126 |   test.describe("with less motion", () => {
  127 |     test.use({contextOptions: {reducedMotion: "reduce"}})
  128 | 
  129 |     test("it stays still", async ({page, isMobile}) => {
  130 |       test.skip(isMobile, "the same page as at 1280; one run is enough")
  131 |       await (await askForPreview(page)).click()
  132 |       const preview = previewOf(page)
```