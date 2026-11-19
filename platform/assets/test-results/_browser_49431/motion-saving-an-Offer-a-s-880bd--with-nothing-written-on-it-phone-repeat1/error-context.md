# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> saving an Offer >> a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it
- Location: test/browser/motion.spec.ts:259:3

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mwddrx5o' })
Expected: visible
Error: strict mode violation: getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mwddrx5o' }) resolved to 3 elements:
    1) <li data-saved="" data-phx-loc="117" class="pb-offers-saved-card" id="pb-offers-saved-0ef8eccb-6365-4172-9f30-ad64e1d9aeb0" data-layout-id="pb-offers-saved-0ef8eccb-6365-4172-9f30-ad64e1d9aeb0">…</li> aka getByText('First mwddrx5o v1 Try').first()
    2) <li data-saved="" data-phx-loc="117" class="pb-offers-saved-card" id="pb-offers-saved-4bad1484-b4eb-4d81-8542-ed7c37d5aea2" data-layout-id="pb-offers-saved-4bad1484-b4eb-4d81-8542-ed7c37d5aea2">…</li> aka getByText('First mwddrx5o v1 Try').nth(1)
    3) <li data-saved="" data-phx-loc="117" class="pb-offers-saved-card" id="pb-offers-saved-a839eaec-c8fb-447c-8546-949fc86d6191" data-layout-id="pb-offers-saved-a839eaec-c8fb-447c-8546-949fc86d6191">…</li> aka locator('#pb-offers-saved-a839eaec-c8fb-447c-8546-949fc86d6191')

Call log:
  - Expect "toBeVisible" getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mwddrx5o' }) with timeout 5000ms
  - waiting for getByRole('region', { name: 'Saved Offers' }).getByRole('list', { name: 'Saved Offers, scroll horizontally' }).getByRole('listitem').filter({ hasText: 'First mwddrx5o' })

```

# Page snapshot

```yaml
- generic [ref=e1]:
  - link "Skip to the main content" [ref=e2] [cursor=pointer]:
    - /url: "#pb-content"
  - generic [ref=e3]:
    - banner [ref=e6]:
      - link "Patchbay home" [ref=e7] [cursor=pointer]:
        - /url: /
      - generic [ref=e25]:
        - button "Search" [ref=e26] [cursor=pointer]
        - button "Menu" [ref=e30] [cursor=pointer]
      - button "0xeeee..eeee" [ref=e32] [cursor=pointer]
    - main [ref=e42]:
      - heading "Agent Offers" [level=1] [ref=e64]
      - navigation "Agent Offers pages" [ref=e65]:
        - link "Slots" [ref=e66] [cursor=pointer]:
          - /url: /offers
        - link "Your Offers" [ref=e67] [cursor=pointer]:
          - /url: /offers/create
        - link "Active" [ref=e68] [cursor=pointer]:
          - /url: /offers/active
        - link "History" [ref=e69] [cursor=pointer]:
          - /url: /offers/history
        - link "Guide" [ref=e70] [cursor=pointer]:
          - /url: /offers/how-it-works
      - status [ref=e71]: Screening paused · saved Offers will wait for approval
      - generic [ref=e72]:
        - region [ref=e73]:
          - generic [ref=e74]:
            - heading "New Offer" [level=2] [ref=e75]
            - button "About saving an Offer" [ref=e77] [cursor=pointer]
          - generic [ref=e80]:
            - generic [ref=e81]:
              - generic [ref=e82]: Private name
              - textbox "Private name" [ref=e84]
            - generic [ref=e86]:
              - generic [ref=e87]: Offer text
              - textbox "Offer text" [ref=e89]
              - generic [ref=e90]: 0/160 characters · 0/640 bytes
            - button "Save Offer" [active] [ref=e92] [cursor=pointer]
        - region [ref=e95]:
          - generic [ref=e96]:
            - heading "Saved Offers" [level=2] [ref=e97]
            - generic [ref=e98]:
              - generic [ref=e99]:
                - generic [ref=e100]: "3"
                - generic [aria-hidden] [ref=e102]: "3"
              - text: saved ↔
          - list "Saved Offers, scroll horizontally" [ref=e103]:
            - listitem [ref=e104]:
              - generic [ref=e105]:
                - strong [ref=e106]: First mwddrx5o
                - generic [ref=e107]:
                  - generic [ref=e108]: v1
                  - button "Delete First mwddrx5o" [ref=e109] [cursor=pointer]
              - blockquote [ref=e113]: Try Patchbay to fix the tools on your site. First mwddrx5o
              - list "Approval status" [ref=e114]:
                - listitem [ref=e115]:
                  - generic [ref=e116]: Safety
                  - strong [ref=e117]: Waiting
              - group [ref=e118]:
                - generic "Screening details" [ref=e119] [cursor=pointer]
              - button "Edit text" [ref=e121] [cursor=pointer]
            - listitem [ref=e124]:
              - generic [ref=e125]:
                - strong [ref=e126]: First mwddrx5o
                - generic [ref=e127]:
                  - generic [ref=e128]: v1
                  - button "Delete First mwddrx5o" [ref=e129] [cursor=pointer]
              - blockquote [ref=e133]: Try Patchbay to fix the tools on your site. First mwddrx5o
              - list "Approval status" [ref=e134]:
                - listitem [ref=e135]:
                  - generic [ref=e136]: Safety
                  - strong [ref=e137]: Waiting
              - group [ref=e138]:
                - generic "Screening details" [ref=e139] [cursor=pointer]
              - button "Edit text" [ref=e141] [cursor=pointer]
            - listitem [ref=e144]:
              - generic [ref=e145]:
                - strong [ref=e146]: First mwddrx5o
                - generic [ref=e147]:
                  - generic [ref=e148]: v1
                  - button "Delete First mwddrx5o" [ref=e149] [cursor=pointer]
              - blockquote [ref=e153]: Try Patchbay to fix the tools on your site. First mwddrx5o
              - list "Approval status" [ref=e154]:
                - listitem [ref=e155]:
                  - generic [ref=e156]: Safety
                  - strong [ref=e157]: Waiting
              - group [ref=e158]:
                - generic "Screening details" [ref=e159] [cursor=pointer]
              - button "Edit text" [ref=e161] [cursor=pointer]
    - contentinfo [ref=e166]:
      - generic [ref=e167]:
        - link "Patchbay on X" [ref=e168] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=e171] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=e174]:
        - link "Buy $REGENT" [ref=e175] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=e176] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=e177] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=e178] [cursor=pointer]
        - generic [ref=e179]:
          - link "Privacy policy" [ref=e180] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=e181] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=e182]: © 2026 Regents Labs
```

# Test source

```ts
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
  210 |     await page.getByRole("textbox", {name: "Agent name"}).fill("Not A Name!")
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
  228 |   // What is wrong with a wording is said under its field, in words that say
  229 |   // what to do: never while it is typed, once the field is left, and when a
  230 |   // save is refused. Typing takes the line away once the wording is right.
  231 |   test("a wording's problem shows under its field once the field is left, and on a refused save", async ({page}) => {
  232 |     const problems = watch(page)
  233 |     await page.goto("/offers/create")
  234 |     await connected(page)
  235 |     const wording = page.getByRole("textbox", {name: "Offer text"})
  236 |     const reason = page.locator("#pb-offers-text-errors p")
  237 |     const saved = await page.getByRole("region", {name: "Saved Offers"}).getByRole("listitem").count()
  238 | 
  239 |     await page.getByRole("textbox", {name: "Private name"}).fill("Two lines")
  240 |     await wording.fill("Try Patchbay.\nOn two lines.")
  241 |     await expect(page.locator("#pb-offers-text-hint")).toContainText("27/160 characters")
  242 |     await expect(reason).toHaveCount(0)
  243 | 
  244 |     await wording.blur()
  245 |     await expect(reason).toBeVisible()
  246 |     await expect(wording).toHaveAttribute("aria-invalid", "true")
  247 | 
  248 |     await wording.fill("Try Patchbay on one line.")
  249 |     await expect(reason).toHaveCount(0)
  250 | 
  251 |     await wording.fill("Try Patchbay.\nOn two lines.")
  252 |     await page.getByRole("button", {name: "Save Offer"}).click()
  253 |     await expect(reason).toBeVisible()
  254 |     await expect(page.locator("#pb-offers-create-problem")).toHaveCount(0)
  255 |     await expect(page.getByRole("region", {name: "Saved Offers"}).getByRole("listitem")).toHaveCount(saved)
  256 |     await problems.expect()
  257 |   })
  258 | 
  259 |   test("a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it", async ({
  260 |     page,
  261 |   }) => {
  262 |     const problems = watch(page)
  263 |     await page.goto("/offers/create")
  264 |     await connected(page)
  265 |     const saved = page.getByRole("region", {name: "Saved Offers"})
  266 |     const count = saved.getByText(/^\d+ saved/)
  267 |     const row = saved.getByRole("list", {name: "Saved Offers, scroll horizontally"})
  268 |     const cards = row.getByRole("listitem")
  269 | 
  270 |     const save = async (label: string) => {
  271 |       const before = await count.textContent()
  272 |       await page.getByRole("textbox", {name: "Private name"}).fill(label)
  273 |       await page.getByRole("textbox", {name: "Offer text"}).fill(`Try Patchbay to fix the tools on your site. ${label}`)
  274 |       await page.getByRole("button", {name: "Save Offer"}).click()
> 275 |       await expect(cards.filter({hasText: label})).toBeVisible()
      |                                                    ^ Error: expect(locator).toBeVisible() failed
  276 |       await expect(count).not.toHaveText(before!)
  277 |     }
  278 | 
  279 |     const rested = async () => {
  280 |       await toRest(row)
  281 |       for (const card of await cards.all()) {
  282 |         await toRest(card)
  283 |         expect(
  284 |           await card.evaluate(el => {
  285 |             const style = getComputedStyle(el)
  286 |             return [style.translate, style.transform, style.opacity]
  287 |           }),
  288 |         ).toEqual(["none", "none", "1"])
  289 |       }
  290 |       // The count is the plain figure again, not the pieces it rolled in.
  291 |       await expect(count).toHaveText(/^\d+ saved/)
  292 |       expect(await count.evaluate(el => el.firstElementChild?.childElementCount)).toBe(0)
  293 |     }
  294 | 
  295 |     const first = `First ${Date.now().toString(36)}`
  296 |     await save(first)
  297 |     await rested()
  298 |     await forgetMoves(page)
  299 | 
  300 |     const second = `Second ${Date.now().toString(36)}`
  301 |     await watchInside(count)
  302 |     await save(second)
  303 |     await rested()
  304 |     const arrived = await movesOf(cards.filter({hasText: second}))
  305 |     expect(fades(arrived)).toBe(true)
  306 |     // The new card comes first, in the row's view, whole, not scrolled past.
  307 |     await expect(cards.first()).toContainText(second)
  308 |     const [seen, card] = [await row.boundingBox(), await cards.filter({hasText: second}).boundingBox()]
  309 |     expect(card!.x).toBeGreaterThanOrEqual(seen!.x)
  310 |     expect(card!.x + card!.width).toBeLessThanOrEqual(seen!.x + seen!.width)
  311 |     expect((await movesInside(count)).some(move => move.includes("translateY"))).toBe(true)
  312 |     expect(slides(arrived)).toBe(false)
  313 |     // Nor does the stylesheet move it on its way in.
  314 |     expect(arrived.filter(move => /^(animation|transition) /.test(move))).toEqual([])
  315 |     expect(slides(await movesOf(cards.filter({hasText: first})))).toBe(true)
  316 |     await problems.expect()
  317 |   })
  318 | })
  319 | 
  320 | test("Claude's picture tilts under a mouse and stays put after a tap", async ({page, isMobile}) => {
  321 |   await page.goto("/claude")
  322 |   // The crowd is decoration, hidden from assistive technology; its first figure.
  323 |   const hero = page.getByRole("region", {name: "Claude Code", exact: true})
  324 |   const figure = hero.getByRole("img", {includeHidden: true}).first()
  325 |   if (isMobile) {
  326 |     await figure.tap({force: true})
  327 |     // The tap leaves the picture hovered, as a phone does; asking for its
  328 |     // animations brings its style up to date, so a tilt it set off is there.
  329 |     expect(await figure.evaluate(el => el.matches(":hover"))).toBe(true)
  330 |     expect(await figure.evaluate(el => [el.getAnimations().length, getComputedStyle(el).transform])).toEqual([0, "none"])
  331 |   } else {
  332 |     expect(await figure.evaluate(el => getComputedStyle(el).transitionDuration)).toBe("0.28s")
  333 |     await figure.hover({force: true})
  334 |     await expect.poll(() => figure.evaluate(el => getComputedStyle(el).transform)).not.toBe("none")
  335 |   }
  336 | })
  337 | 
```