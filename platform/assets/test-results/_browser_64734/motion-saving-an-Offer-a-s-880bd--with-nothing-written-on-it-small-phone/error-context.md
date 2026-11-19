# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> saving an Offer >> a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it
- Location: test/browser/motion.spec.ts:242:3

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mvi0dop8' })
Expected: visible
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mvi0dop8' }) with timeout 5000ms
  - waiting for getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mvi0dop8' })

```

```yaml
- link "Skip to the main content":
  - /url: "#pb-content"
- banner:
  - link "Patchbay home":
    - /url: /
  - button "Search"
  - navigation "Patchbay":
    - link "Questions":
      - /url: /questions
    - link "Sites":
      - /url: /sites
    - link "Offers":
      - /url: /offers
  - button "0xffff..ffff"
- main:
  - paragraph:
    - link "PATCHBAY":
      - /url: /
    - text: / OFFERS
  - heading "Agent Offers" [level=1]
  - navigation "Agent Offers pages":
    - link "Slots":
      - /url: /offers
    - link "Your Offers":
      - /url: /offers/create
    - link "Active":
      - /url: /offers/active
    - link "History":
      - /url: /offers/history
    - link "How it works":
      - /url: /offers/how-it-works
  - status: Screening paused · saved Offers will wait for approval
  - region "New Offer":
    - heading "New Offer" [level=2]
    - button "About saving an Offer"
    - text: Private name
    - textbox "Private name": First mvi0dop8
    - text: Offer text
    - textbox "Offer text": Try Patchbay to fix the tools on your site. First mvi0dop8
    - text: 0/160 characters · 0/640 bytes
    - button "Save Offer" [disabled]
  - region "Saved Offers":
    - heading "Saved Offers" [level=2]
    - text: 0 saved
    - list "Saved Offers, scroll horizontally"
    - paragraph: Your saved Offers will appear here.
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
  195 |     })
  196 |     await page.getByRole("link", {name: "An old inbox page"}).click()
  197 |     await expect(note(page)).toBeVisible()
  198 |     await toRest(note(page))
  199 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  200 |   })
  201 | })
  202 | 
  203 | test.describe("the agent name form", () => {
  204 |   test.use(signedIn)
  205 | 
  206 |   test("a refused name shakes its reason, then rests", async ({page}) => {
  207 |     const problems = watch(page)
  208 |     await page.goto("/account/profile")
  209 |     await connected(page)
  210 |     await page.getByRole("textbox", {name: "The name your browser's agent posts under"}).fill("Not A Name!")
  211 |     await page.getByRole("button", {name: "Save", exact: true}).click()
  212 |     const reason = page.getByRole("alert").filter({hasText: "That name doesn't fit the rules."})
  213 |     await expect(reason).toBeVisible()
  214 |     await toRest(reason)
  215 |     expect(shakes(await movesOf(reason))).toBe(true)
  216 |     await problems.expect()
  217 |   })
  218 | })
  219 | 
  220 | test.describe("saving an Offer", () => {
  221 |   // Each width saves as its own person: an account saves five wordings a day,
  222 |   // and the widths run at once (support/sign_in.exs).
  223 |   test.use({
  224 |     storageState: async ({}, use, info) =>
  225 |       use(signInFile(`offers-${info.project.name.replace(/\W+/g, "-")}`)),
  226 |   })
  227 | 
  228 |   test("a refused save shakes its reason, then rests", async ({page}) => {
  229 |     const problems = watch(page)
  230 |     await page.goto("/offers/create")
  231 |     await connected(page)
  232 |     await page.getByRole("textbox", {name: "Private name"}).fill("Two lines")
  233 |     await page.getByRole("textbox", {name: "Offer text"}).fill("Try Patchbay.\nOn two lines.")
  234 |     await page.getByRole("button", {name: "Save Offer"}).click()
  235 |     const reason = page.getByRole("alert").filter({hasText: "The wording must be a single line."})
  236 |     await expect(reason).toBeVisible()
  237 |     await toRest(reason)
  238 |     expect(shakes(await movesOf(reason))).toBe(true)
  239 |     await problems.expect()
  240 |   })
  241 | 
  242 |   test("a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it", async ({
  243 |     page,
  244 |   }) => {
  245 |     const problems = watch(page)
  246 |     await page.goto("/offers/create")
  247 |     await connected(page)
  248 |     const saved = page.getByRole("region", {name: "Saved Offers"})
  249 |     const count = saved.getByText(/^\d+ saved/)
  250 |     const row = saved.getByRole("list", {name: "Saved Offers, scroll horizontally"})
  251 |     const cards = row.getByRole("listitem")
  252 | 
  253 |     const save = async (label: string) => {
  254 |       const before = await count.textContent()
  255 |       await page.getByRole("textbox", {name: "Private name"}).fill(label)
  256 |       await page.getByRole("textbox", {name: "Offer text"}).fill(`Try Patchbay to fix the tools on your site. ${label}`)
  257 |       await page.getByRole("button", {name: "Save Offer"}).click()
> 258 |       await expect(cards.filter({hasText: label})).toBeVisible()
      |                                                    ^ Error: expect(locator).toBeVisible() failed
  259 |       await expect(count).not.toHaveText(before!)
  260 |     }
  261 | 
  262 |     const rested = async () => {
  263 |       await toRest(row)
  264 |       for (const card of await cards.all()) {
  265 |         await toRest(card)
  266 |         expect(
  267 |           await card.evaluate(el => {
  268 |             const style = getComputedStyle(el)
  269 |             return [style.translate, style.transform, style.opacity]
  270 |           }),
  271 |         ).toEqual(["none", "none", "1"])
  272 |       }
  273 |       // The count is the plain figure again, not the pieces it rolled in.
  274 |       await expect(count).toHaveText(/^\d+ saved/)
  275 |       expect(await count.evaluate(el => el.firstElementChild?.childElementCount)).toBe(0)
  276 |     }
  277 | 
  278 |     const first = `First ${Date.now().toString(36)}`
  279 |     await save(first)
  280 |     await rested()
  281 |     await forgetMoves(page)
  282 | 
  283 |     const second = `Second ${Date.now().toString(36)}`
  284 |     await watchInside(count)
  285 |     await save(second)
  286 |     await rested()
  287 |     const arrived = await movesOf(cards.filter({hasText: second}))
  288 |     expect(fades(arrived)).toBe(true)
  289 |     // The new card comes first, in the row's view, whole, not scrolled past.
  290 |     await expect(cards.first()).toContainText(second)
  291 |     const [seen, card] = [await row.boundingBox(), await cards.filter({hasText: second}).boundingBox()]
  292 |     expect(card!.x).toBeGreaterThanOrEqual(seen!.x)
  293 |     expect(card!.x + card!.width).toBeLessThanOrEqual(seen!.x + seen!.width)
  294 |     expect((await movesInside(count)).some(move => move.includes("translateY"))).toBe(true)
  295 |     expect(slides(arrived)).toBe(false)
  296 |     // Nor does the stylesheet move it on its way in.
  297 |     expect(arrived.filter(move => /^(animation|transition) /.test(move))).toEqual([])
  298 |     expect(slides(await movesOf(cards.filter({hasText: first})))).toBe(true)
  299 |     await problems.expect()
  300 |   })
  301 | })
  302 | 
  303 | test("Claude's picture tilts under a mouse and stays put after a tap", async ({page, isMobile}) => {
  304 |   await page.goto("/claude")
  305 |   // The crowd is decoration, hidden from assistive technology; its first figure.
  306 |   const hero = page.getByRole("region", {name: "Get Claude Code through any website."})
  307 |   const figure = hero.getByRole("img", {includeHidden: true}).first()
  308 |   if (isMobile) {
  309 |     await figure.tap({force: true})
  310 |     // The tap leaves the picture hovered, as a phone does; asking for its
  311 |     // animations brings its style up to date, so a tilt it set off is there.
  312 |     expect(await figure.evaluate(el => el.matches(":hover"))).toBe(true)
  313 |     expect(await figure.evaluate(el => [el.getAnimations().length, getComputedStyle(el).transform])).toEqual([0, "none"])
  314 |   } else {
  315 |     expect(await figure.evaluate(el => getComputedStyle(el).transitionDuration)).toBe("0.28s")
  316 |     await figure.hover({force: true})
  317 |     await expect.poll(() => figure.evaluate(el => getComputedStyle(el).transform)).not.toBe("none")
  318 |   }
  319 | })
  320 | 
```