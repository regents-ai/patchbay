# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: first_screen.spec.ts >> on a phone >> every control on /incidents is a full finger tall
- Location: test/browser/first_screen.spec.ts:56:5

# Error details

```
Error: page.goto: net::ERR_ABORTED at http://127.0.0.1:63004/incidents
Call log:
  - navigating to "http://127.0.0.1:63004/incidents", waiting until "load"

```

# Test source

```ts
  1   | import {expect, test, watch} from "./support/test"
  2   | 
  3   | // The 29 Oct UI audit (PB-12, PB-14): on a phone the home page and a site's page
  4   | // reach a post on the first screen, every control a finger presses is a full
  5   | // 44 px tall, and the Wallet Bench board takes the sheet's whole width.
  6   | 
  7   | // What a phone's first screen holds: a row's top above the screen's bottom.
  8   | const firstRowTop = (page: import("@playwright/test").Page) =>
  9   |   page.locator(".pb-row").first().evaluate(row => row.getBoundingClientRect().top)
  10  | 
  11  | test.describe("on a phone", () => {
  12  |   test.skip(({isMobile}) => !isMobile, "checked at 390 and 320 wide")
  13  | 
  14  |   test("the home page reaches its first post on the first screen, with one search box", async ({page}) => {
  15  |     const problems = watch(page)
  16  |     await page.goto("/")
  17  |     expect(await firstRowTop(page)).toBeLessThan(page.viewportSize()!.height)
  18  | 
  19  |     const searches = await page.locator("input[type=search]").evaluateAll(fields =>
  20  |       fields.filter(field => {
  21  |         const box = field.getBoundingClientRect()
  22  |         return box.height > 0 && box.top < window.innerHeight
  23  |       }).length,
  24  |     )
  25  |     expect(searches).toBe(1)
  26  |     await expect(page.locator("#shell-search-button")).toHaveCount(0)
  27  |     await problems.expect()
  28  |   })
  29  | 
  30  |   test("a site's page reaches its first post on the first screen", async ({page}) => {
  31  |     const problems = watch(page)
  32  |     await page.goto("/keyfleet.ai")
  33  |     expect(await firstRowTop(page)).toBeLessThan(page.viewportSize()!.height)
  34  |     await problems.expect()
  35  |   })
  36  | 
  37  |   // Links inside running text (a block with three or more words of its own
  38  |   // besides its links) keep their line's height; a link in a short line, such
  39  |   // as a page's way back, is checked. The shared address piece's icons are
  40  |   // design-system's and are sized there.
  41  |   const paths = [
  42  |     "/",
  43  |     "/keyfleet.ai",
  44  |     "/help",
  45  |     "/sites",
  46  |     "/wallet-bench",
  47  |     "/wallet-bench/how-it-works",
  48  |     "/changelog",
  49  |     "/offers",
  50  |     "/incidents",
  51  |     "/hermes",
  52  |     "/hermes/troubleshooting",
  53  |     "/agents",
  54  |   ]
  55  |   for (const path of paths) {
  56  |     test(`every control on ${path} is a full finger tall`, async ({page}) => {
> 57  |       await page.goto(path)
      |                  ^ Error: page.goto: net::ERR_ABORTED at http://127.0.0.1:63004/incidents
  58  |       const small = await page
  59  |         .locator("a[href], button, summary, select, input:not([type=hidden])")
  60  |         .evaluateAll(controls => {
  61  |           const inRunningText = (control: Element) => {
  62  |             let block = control.parentElement
  63  |             while (block && getComputedStyle(block).display.startsWith("inline")) block = block.parentElement
  64  |             if (!block) return false
  65  |             const words = block.cloneNode(true) as Element
  66  |             words.querySelectorAll("a, button").forEach(part => part.remove())
  67  |             return words.textContent!.trim().split(/\s+/).filter(word => /\w/.test(word)).length >= 3
  68  |           }
  69  |           return controls
  70  |             .filter(control => {
  71  |               const box = control.getBoundingClientRect()
  72  |               const style = getComputedStyle(control)
  73  |               if (box.width <= 1 || box.height <= 1 || style.visibility === "hidden") return false
  74  |               if (control.closest(".rg-address, .visually-hidden")) return false
  75  |               if (style.display === "inline" && inRunningText(control)) return false
  76  |               return box.height < 44 || box.width < 24
  77  |             })
  78  |             .map(control => {
  79  |               const box = control.getBoundingClientRect()
  80  |               const name = (control.textContent || control.getAttribute("aria-label") || "").trim().slice(0, 30)
  81  |               return `${control.tagName.toLowerCase()} "${name}" ${Math.round(box.width)}×${Math.round(box.height)}`
  82  |             })
  83  |         })
  84  |       expect(small, "controls under 44 px tall or 24 px wide").toEqual([])
  85  |     })
  86  |   }
  87  | })
  88  | 
  89  | test("the Wallet Bench board takes the sheet's width", async ({page, isMobile}) => {
  90  |   const problems = watch(page)
  91  |   await page.goto("/wallet-bench")
  92  | 
  93  |   const {sheetRight, boardRight, frameWidth, tableWidth} = await page.evaluate(() => {
  94  |     const sheet = document.querySelector<HTMLElement>(".pb-wb-sheet")!
  95  |     const frame = document.querySelector<HTMLElement>(".pb-wb-scroll")!
  96  |     const inner = sheet.getBoundingClientRect().right - parseFloat(getComputedStyle(sheet).paddingRight)
  97  |     return {
  98  |       sheetRight: inner,
  99  |       boardRight: frame.getBoundingClientRect().right,
  100 |       frameWidth: frame.clientWidth,
  101 |       tableWidth: frame.querySelector("table")!.getBoundingClientRect().width,
  102 |     }
  103 |   })
  104 |   // The frame reaches the sheet's inner edge; on a wide screen the board fills
  105 |   // the frame, and on a phone it is wider and scrolls inside it.
  106 |   expect(Math.abs(sheetRight - boardRight)).toBeLessThanOrEqual(1)
  107 |   if (isMobile) expect(tableWidth).toBeGreaterThan(frameWidth)
  108 |   else expect(Math.abs(tableWidth - frameWidth)).toBeLessThanOrEqual(1)
  109 |   await problems.expect()
  110 | })
  111 | 
  112 | // Layers: Geist at 400 and 600 only, and nothing floats on a blurred shadow.
  113 | // The theme switch is design-system's artwork (its laser's glow is drawn
  114 | // there), so it is left to design-system's own checks.
  115 | for (const path of ["/", "/sites", "/wallet-bench", "/offers", "/keyfleet.ai", "/changelog", "/agent-setup"]) {
  116 |   test(`${path} draws text at 400 and 600 only, with no soft shadows`, async ({page}) => {
  117 |     await page.goto(path)
  118 |     const found = await page.evaluate(() => {
  119 |       const weights: string[] = []
  120 |       const shadows: string[] = []
  121 |       for (const element of document.querySelectorAll<HTMLElement>("body *")) {
  122 |         const box = element.getBoundingClientRect()
  123 |         if (box.width === 0 || box.height === 0 || element.closest(".rg-theme-toggle")) continue
  124 |         const style = getComputedStyle(element)
  125 |         const words = [...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent!.trim())
  126 |         if (words && !["400", "600"].includes(style.fontWeight)) weights.push(`${element.tagName} ${style.fontWeight}`)
  127 |         // Each shadow is "colour x y blur spread"; a blur above zero is a soft shadow.
  128 |         for (const shadow of style.boxShadow === "none" ? [] : style.boxShadow.split(/,(?![^(]*\))/)) {
  129 |           const lengths = shadow.replace(/\w+\([^)]*\)/g, "").match(/-?[\d.]+px/g) ?? []
  130 |           if (parseFloat(lengths[2] ?? "0") > 0) shadows.push(`${element.tagName}.${element.className} ${shadow}`)
  131 |         }
  132 |       }
  133 |       return {weights: [...new Set(weights)], shadows: [...new Set(shadows)]}
  134 |     })
  135 |     expect(found).toEqual({weights: [], shadows: []})
  136 |   })
  137 | }
  138 | 
```