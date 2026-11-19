# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> the home page's preview >> the buttons stay put while the address is looked at and answered
- Location: test/browser/motion.spec.ts:81:3

# Error details

```
Error: expect(locator).toHaveAccessibleDescription(expected) failed

Locator:  getByRole('textbox', { name: 'The site' })
Expected: "That address does not lead to any site."
Received: "Looking for WebMCP tools at this address…"
Timeout:  5000ms

Call log:
  - Expect "toHaveAccessibleDescription" getByRole('textbox', { name: 'The site' }) with timeout 5000ms
  - waiting for getByRole('textbox', { name: 'The site' })
    14 × locator resolved to <input value="" type="text" required="" inputmode="url" id="pb-fix-site" maxlength="2048" data-phx-loc="44" autocomplete="url" spellcheck="false" name="ask[site_url]" autocapitalize="none" placeholder="example.com/app" aria-describedby="pb-fix-site-check"/>
       - unexpected value "Looking for WebMCP tools at this address…"

```

```yaml
- textbox "The site":
  - /placeholder: example.com/app
  - text: https://example.com
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
  29  | // The home page's post form, opened by its link, filled in, and its button that
  30  | // asks for a preview.
  31  | async function askForPreview(page: Page, title = "Book a table for two on Friday") {
  32  |   await page.goto("/?ask=1")
  33  |   await page.getByRole("textbox", {name: "Issue", exact: true}).fill(title)
  34  |   await page.getByRole("textbox", {name: "The site"}).fill("https://example.com")
  35  |   return page.getByRole("button", {name: "Post to agent forum"})
  36  | }
  37  | 
  38  | const previewOf = (page: Page) => page.getByRole("region", {name: "Your post, exactly as everyone will see it"})
  39  | 
  40  | // Read once the next frame is drawn, when a motion started with the preview has
  41  | // written its first step: nothing moved on it or inside it, from a script or the
  42  | // stylesheet, and nothing is moving.
  43  | async function staysStill(preview: Locator) {
  44  |   await preview.page().evaluate(() => new Promise(drawn => requestAnimationFrame(drawn)))
  45  |   expect(await movesWithin(preview)).toEqual([])
  46  |   expect(await preview.evaluate(el => el.getAnimations({subtree: true}).length)).toBe(0)
  47  |   expect(await inlineStyle(preview)).toBe("")
  48  | }
  49  | 
  50  | test.describe("the home page's preview", () => {
  51  |   test("asked for by hand, it settles in and ends at rest", async ({page, isMobile}) => {
  52  |     await press(await askForPreview(page), isMobile)
  53  |     const preview = previewOf(page)
  54  |     await expect(preview).toBeVisible()
  55  |     await toRest(preview)
  56  |     expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  57  |   })
  58  | 
  59  |   test("with a box asking to check something private, it settles in whole, and the box does not shake", async ({
  60  |     page,
  61  |     isMobile,
  62  |   }) => {
  63  |     await press(await askForPreview(page, "Book a table for two, then mail me at diner@example.com"), isMobile)
  64  |     const preview = previewOf(page)
  65  |     const check = preview.getByRole("alert").filter({hasText: "Check before posting."})
  66  |     await expect(check).toBeVisible()
  67  |     await toRest(preview)
  68  |     expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  69  |     expect(shakes(await movesWithin(check))).toBe(false)
  70  |   })
  71  | 
  72  |   test("a refused preview shakes its reason, then rests", async ({page, isMobile}) => {
  73  |     await press(await askForPreview(page, `Book a table for two on Friday ${"and again ".repeat(15)}`), isMobile)
  74  |     const reason = page.getByRole("alert").filter({hasText: "A forum post's title is what you are trying to do"})
  75  |     await expect(reason).toBeVisible()
  76  |     await toRest(reason)
  77  |     expect(shakes(await movesOf(reason))).toBe(true)
  78  |     await expect(previewOf(page)).toHaveCount(0)
  79  |   })
  80  | 
  81  |   test("the buttons stay put while the address is looked at and answered", async ({page}) => {
  82  |     // The post button and the details toggle. On a phone both are under the
  83  |     // address; on a desktop the post button stands beside the question and the
  84  |     // toggle is under the address.
  85  |     const controls = [await askForPreview(page), page.getByRole("group").getByText("Details help find a solution")]
  86  |     const places = () => Promise.all(controls.map(control => control.boundingBox()))
  87  |     const before = await places()
  88  |     // Leaving the field asks at once, as a tap on the button does; what is
  89  |     // found is said under it, as the field's description.
  90  |     const site = page.getByRole("textbox", {name: "The site"})
  91  |     await site.blur()
  92  |     await expect(site).toHaveAccessibleDescription("Looking for WebMCP tools at this address…")
  93  |     expect(await places()).toEqual(before)
> 94  |     await expect(site).toHaveAccessibleDescription("That address does not lead to any site.")
      |                        ^ Error: expect(locator).toHaveAccessibleDescription(expected) failed
  95  |     expect(await places()).toEqual(before)
  96  |   })
  97  | 
  98  |   test("asked for from the keyboard, it stays still", async ({page, isMobile}) => {
  99  |     test.skip(isMobile, "a phone has no keyboard to ask with")
  100 |     const ask = await askForPreview(page)
  101 |     await ask.focus()
  102 |     await page.keyboard.press("Enter")
  103 |     const preview = previewOf(page)
  104 |     await expect(preview).toBeVisible()
  105 |     await staysStill(preview)
  106 |   })
  107 | 
  108 |   test("asked for from the keyboard, it stays still when the mouse moves during the wait", async ({page, isMobile}) => {
  109 |     test.skip(isMobile, "a phone has no keyboard to ask with")
  110 |     let answered!: () => void
  111 |     const held = new Promise<void>(resolve => (answered = resolve))
  112 |     await page.route("**/threads/preview", async route => {
  113 |       const response = await route.fetch()
  114 |       await held
  115 |       await route.fulfill({response})
  116 |     })
  117 |     const ask = await askForPreview(page)
  118 |     await ask.focus()
  119 |     await page.keyboard.press("Enter")
  120 |     for (const x of [200, 400, 600]) await page.mouse.move(x, 300)
  121 |     answered()
  122 |     const preview = previewOf(page)
  123 |     await expect(preview).toBeVisible()
  124 |     await staysStill(preview)
  125 |   })
  126 | 
  127 |   test.describe("with less motion", () => {
  128 |     test.use({contextOptions: {reducedMotion: "reduce"}})
  129 | 
  130 |     test("it stays still", async ({page, isMobile}) => {
  131 |       test.skip(isMobile, "the same page as at 1280; one run is enough")
  132 |       await (await askForPreview(page)).click()
  133 |       const preview = previewOf(page)
  134 |       await expect(preview).toBeVisible()
  135 |       await staysStill(preview)
  136 |     })
  137 |   })
  138 | })
  139 | 
  140 | test.describe("a note above the page", () => {
  141 |   const note = (page: Page) => page.getByRole("alert").filter({hasText: "There is no fix to show at that address."})
  142 | 
  143 |   test("shakes, then rests, after a full page load", async ({page}) => {
  144 |     await page.goto(MISSING_FIX)
  145 |     await expect(note(page)).toBeVisible()
  146 |     await toRest(note(page))
  147 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  148 |   })
  149 | 
  150 |   test("shakes, then rests, after a live page sends the reader on", async ({page}) => {
  151 |     await page.goto("/offers")
  152 |     await connected(page)
  153 |     // A link a live page follows by sending the reader to another page.
  154 |     await page.getByRole("main").evaluate((main, missing) => {
  155 |       const link = document.createElement("a")
  156 |       link.textContent = "A fix that is not there"
  157 |       link.href = missing
  158 |       link.dataset.phxLink = "redirect"
  159 |       link.dataset.phxLinkState = "push"
  160 |       main.prepend(link)
  161 |     }, MISSING_FIX)
  162 |     await page.getByRole("link", {name: "A fix that is not there"}).click()
  163 |     await expect(page).toHaveURL("/")
  164 |     await expect(note(page)).toBeVisible()
  165 |     await toRest(note(page))
  166 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  167 |   })
  168 | })
  169 | 
  170 | test.describe("the inbox's note about an old page link", () => {
  171 |   test.use(signedIn)
  172 |   const note = (page: Page) => page.getByRole("alert").filter({hasText: "That inbox page link no longer works."})
  173 | 
  174 |   test("shakes, then rests, after a full page load", async ({page}) => {
  175 |     const problems = watch(page)
  176 |     await page.goto("/account/inbox?after=not-a-page")
  177 |     await connected(page)
  178 |     await expect(note(page)).toBeVisible()
  179 |     await toRest(note(page))
  180 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  181 |     await problems.expect()
  182 |   })
  183 | 
  184 |   test("shakes, then rests, after a live change of page", async ({page}) => {
  185 |     await page.goto("/account/inbox")
  186 |     await connected(page)
  187 |     // A link a live page follows without loading the page again.
  188 |     await page.getByRole("main").evaluate(main => {
  189 |       const link = document.createElement("a")
  190 |       link.textContent = "An old inbox page"
  191 |       link.href = "/account/inbox?after=not-a-page"
  192 |       link.dataset.phxLink = "patch"
  193 |       link.dataset.phxLinkState = "push"
  194 |       main.prepend(link)
```