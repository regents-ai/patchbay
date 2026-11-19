# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: value_cards.spec.ts >> every card draws its panel, outlasts the pointer and fits the screen
- Location: test/browser/value_cards.spec.ts:55:1

# Error details

```
Error: expect(locator).toHaveAttribute(expected) failed

Locator:  locator(':is(#cards-top, #cards-row) > li').nth(3)
Expected: "true"
Received: "false"
Timeout:  5000ms

Call log:
  - Expect "toHaveAttribute" locator(':is(#cards-top, #cards-row) > li').nth(3) with timeout 5000ms
  - waiting for locator(':is(#cards-top, #cards-row) > li').nth(3)
    2 × locator resolved to <li data-phx-loc="63" id="cards-row-pair" phx-hook="ValueCard" data-value-card="pair" class="value-cards__card" phx-mounted="[["ignore_attrs",{"attrs":["data-value-card-ready"]}]]">…</li>
      - unexpected value "null"
    12 × locator resolved to <li data-phx-loc="63" id="cards-row-pair" phx-hook="ValueCard" data-value-card="pair" class="value-cards__card" data-value-card-ready="false" phx-mounted="[["ignore_attrs",{"attrs":["data-value-card-ready"]}]]">…</li>
       - unexpected value "false"

```

```yaml
- listitem:
  - link "Agents Bring your agent. Pair an agent with your account so it can post and reply for you. Pair agent":
    - /url: /agents
```

# Test source

```ts
  1   | import type {Locator, Page} from "@playwright/test"
  2   | import {expect, test} from "./support/test"
  3   | 
  4   | // The value cards on the home page (PatchbayWeb.Components.ValueCards): three small
  5   | // cards over the search and three full ones at the foot, each a GPU panel over its
  6   | // still frame. The row's first version crashed the browser at phone width (the
  7   | // Regent template's CHANGELOG, 12 Nov 2026), so these open it at 1280 on a desktop
  8   | // and at 390 and 320 on a phone with the GPU on, move a pointer over every card,
  9   | // and ask that the page lived, every panel drew, each row fills its columns, the
  10  | // small cards stay in one row and well under the full ones' height, and nothing
  11  | // reaches past the screen's edge. Then the two ways a visitor keeps the still
  12  | // frames: less motion asked for, and a browser without WebGPU.
  13  | test.use({launchOptions: {args: ["--enable-unsafe-webgpu", "--enable-gpu"]}})
  14  | 
  15  | // The page's script heap after the moves: far above what six panels need, far below
  16  | // the gigabyte the crash reached.
  17  | const HEAP_CEILING = 64 * 1024 * 1024
  18  | 
  19  | const top = (page: Page) => page.locator("#cards-top > li")
  20  | const bottom = (page: Page) => page.locator("#cards-row > li")
  21  | const cards = (page: Page) => page.locator(":is(#cards-top, #cards-row) > li")
  22  | 
  23  | async function open(page: Page) {
  24  |   await page.goto("/")
  25  |   await expect(page.locator("[data-phx-session].phx-connected:has(#shell-search)")).toBeAttached()
  26  |   await expect(top(page)).toHaveCount(3)
  27  |   await expect(bottom(page)).toHaveCount(3)
  28  | }
  29  | 
  30  | // Every still frame arrives, each scrolled to as a visitor would.
  31  | async function stillsArrive(page: Page) {
  32  |   for (const still of await page.locator(":is(#cards-top, #cards-row) .value-cards__still").all()) {
  33  |     await still.scrollIntoViewIfNeeded()
  34  |     await expect.poll(() => still.evaluate((image: HTMLImageElement) => image.naturalWidth)).toBeGreaterThan(0)
  35  |   }
  36  | }
  37  | 
  38  | async function sweep(page: Page) {
  39  |   for (const card of await cards(page).all()) {
  40  |     await card.scrollIntoViewIfNeeded()
  41  |     const box = (await card.boundingBox())!
  42  |     await page.mouse.move(box.x + 4, box.y + 4)
  43  |     await page.mouse.move(box.x + box.width - 4, box.y + box.height - 4, {steps: 12})
  44  |   }
  45  | }
  46  | 
  47  | const sideways = (page: Page) =>
  48  |   page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  49  | 
  50  | const columns = (row: Locator) =>
  51  |   row.evaluateAll(items => new Set(items.map(item => Math.round(item.getBoundingClientRect().left))).size)
  52  | 
  53  | const heights = (row: Locator) => row.evaluateAll(items => items.map(item => item.getBoundingClientRect().height))
  54  | 
  55  | test("every card draws its panel, outlasts the pointer and fits the screen", async ({page, isMobile}) => {
  56  |   let crashed = false
  57  |   page.on("crash", () => { crashed = true })
  58  | 
  59  |   for (const {width, wanted} of isMobile ? [{width: 390, wanted: 1}, {width: 320, wanted: 1}] : [{width: 1280, wanted: 3}]) {
  60  |     await page.setViewportSize({width, height: 800})
  61  |     await open(page)
  62  |     await stillsArrive(page)
  63  |     for (const card of await cards(page).all()) {
  64  |       await card.scrollIntoViewIfNeeded()
> 65  |       await expect(card).toHaveAttribute("data-value-card-ready", "true")
      |                          ^ Error: expect(locator).toHaveAttribute(expected) failed
  66  |     }
  67  | 
  68  |     await sweep(page)
  69  |     await sweep(page)
  70  | 
  71  |     expect(crashed).toBe(false)
  72  |     await expect(cards(page).first()).toHaveAttribute("data-value-card-ready", "true")
  73  |     expect(await columns(top(page))).toBe(3)
  74  |     expect(await columns(bottom(page))).toBe(wanted)
  75  |     expect(Math.max(...await heights(top(page)))).toBeLessThanOrEqual(Math.min(...await heights(bottom(page))) / 2)
  76  |     expect(await sideways(page)).toBe(0)
  77  |     const cdp = await page.context().newCDPSession(page)
  78  |     const {usedSize} = await cdp.send("Runtime.getHeapUsage")
  79  |     expect(usedSize).toBeLessThan(HEAP_CEILING)
  80  |   }
  81  | })
  82  | 
  83  | test.describe("with less motion", () => {
  84  |   test.use({reducedMotion: "reduce"})
  85  | 
  86  |   test("no panel draws and every card keeps its still frame", async ({page}) => {
  87  |     await open(page)
  88  |     await stillsArrive(page)
  89  |     await sweep(page)
  90  |     for (const card of await cards(page).all())
  91  |       await expect(card).not.toHaveAttribute("data-value-card-ready", "true")
  92  |     expect(await sideways(page)).toBe(0)
  93  |   })
  94  | })
  95  | 
  96  | test.describe("without WebGPU", () => {
  97  |   test("every card says it will not draw and keeps its still frame", async ({page}) => {
  98  |     await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "gpu", {get: () => undefined}))
  99  |     await open(page)
  100 |     for (const card of await cards(page).all())
  101 |       await expect(card).toHaveAttribute("data-value-card-ready", "false")
  102 |     await stillsArrive(page)
  103 |     expect(await sideways(page)).toBe(0)
  104 |   })
  105 | })
  106 | 
```