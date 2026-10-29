import {expect, test, watch} from "./support/test"

// The 29 Oct UI audit (PB-12, PB-14): on a phone the home page and a site's page
// reach a post on the first screen, every control a finger presses is a full
// 44 px tall, and the Wallet Bench board takes the sheet's whole width.

// What a phone's first screen holds: a row's top above the screen's bottom.
const firstRowTop = (page: import("@playwright/test").Page) =>
  page.locator(".pb-row").first().evaluate(row => row.getBoundingClientRect().top)

test.describe("on a phone", () => {
  test.skip(({isMobile}) => !isMobile, "checked at 390 and 320 wide")

  test("the home page reaches its first post on the first screen, with one search box", async ({page}) => {
    const problems = watch(page)
    await page.goto("/")
    expect(await firstRowTop(page)).toBeLessThan(page.viewportSize()!.height)

    const searches = await page.locator("input[type=search]").evaluateAll(fields =>
      fields.filter(field => {
        const box = field.getBoundingClientRect()
        return box.height > 0 && box.top < window.innerHeight
      }).length,
    )
    expect(searches).toBe(1)
    await expect(page.locator("#shell-search-button")).toHaveCount(0)
    await problems.expect()
  })

  test("a site's page reaches its first post on the first screen", async ({page}) => {
    const problems = watch(page)
    await page.goto("/keyfleet.ai")
    expect(await firstRowTop(page)).toBeLessThan(page.viewportSize()!.height)
    await problems.expect()
  })

  // Links inside running text keep their line's height; the shared address
  // piece's icons are design-system's and are sized there.
  for (const path of ["/", "/keyfleet.ai", "/help", "/sites", "/wallet-bench", "/changelog"]) {
    test(`every control on ${path} is a full finger tall`, async ({page}) => {
      await page.goto(path)
      const small = await page
        .locator("a[href], button, summary, select, input:not([type=hidden])")
        .evaluateAll(controls =>
          controls
            .filter(control => {
              const box = control.getBoundingClientRect()
              const style = getComputedStyle(control)
              if (box.width <= 1 || box.height <= 1 || style.visibility === "hidden") return false
              if (style.display === "inline" || control.closest(".rg-address, .visually-hidden")) return false
              return box.height < 44 || box.width < 24
            })
            .map(control => {
              const box = control.getBoundingClientRect()
              const name = (control.textContent || control.getAttribute("aria-label") || "").trim().slice(0, 30)
              return `${control.tagName.toLowerCase()} "${name}" ${Math.round(box.width)}×${Math.round(box.height)}`
            }),
        )
      expect(small, "controls under 44 px tall or 24 px wide").toEqual([])
    })
  }
})

test("the Wallet Bench board takes the sheet's width, with no zoom controls", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto("/wallet-bench")
  await expect(page.locator("[data-wb-zoom], [data-wb-fit]")).toHaveCount(0)

  const {sheetRight, boardRight, frameWidth, tableWidth} = await page.evaluate(() => {
    const sheet = document.querySelector<HTMLElement>(".pb-wb-sheet")!
    const frame = document.querySelector<HTMLElement>(".pb-wb-scroll")!
    const inner = sheet.getBoundingClientRect().right - parseFloat(getComputedStyle(sheet).paddingRight)
    return {
      sheetRight: inner,
      boardRight: frame.getBoundingClientRect().right,
      frameWidth: frame.clientWidth,
      tableWidth: frame.querySelector("table")!.getBoundingClientRect().width,
    }
  })
  // The frame reaches the sheet's inner edge; on a wide screen the board fills
  // the frame, and on a phone it is wider and scrolls inside it.
  expect(Math.abs(sheetRight - boardRight)).toBeLessThanOrEqual(1)
  if (isMobile) expect(tableWidth).toBeGreaterThan(frameWidth)
  else expect(Math.abs(tableWidth - frameWidth)).toBeLessThanOrEqual(1)
  await problems.expect()
})

// Layers: Geist at 400 and 600 only, and nothing floats on a blurred shadow.
// The theme switch is design-system's artwork (its laser's glow is drawn
// there), so it is left to design-system's own checks.
for (const path of ["/", "/sites", "/wallet-bench", "/offers", "/keyfleet.ai", "/changelog", "/agent-setup"]) {
  test(`${path} draws text at 400 and 600 only, with no soft shadows`, async ({page}) => {
    await page.goto(path)
    const found = await page.evaluate(() => {
      const weights: string[] = []
      const shadows: string[] = []
      for (const element of document.querySelectorAll<HTMLElement>("body *")) {
        const box = element.getBoundingClientRect()
        if (box.width === 0 || box.height === 0 || element.closest(".rg-theme-toggle")) continue
        const style = getComputedStyle(element)
        const words = [...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent!.trim())
        if (words && !["400", "600"].includes(style.fontWeight)) weights.push(`${element.tagName} ${style.fontWeight}`)
        // Each shadow is "colour x y blur spread"; a blur above zero is a soft shadow.
        for (const shadow of style.boxShadow === "none" ? [] : style.boxShadow.split(/,(?![^(]*\))/)) {
          const lengths = shadow.replace(/\w+\([^)]*\)/g, "").match(/-?[\d.]+px/g) ?? []
          if (parseFloat(lengths[2] ?? "0") > 0) shadows.push(`${element.tagName}.${element.className} ${shadow}`)
        }
      }
      return {weights: [...new Set(weights)], shadows: [...new Set(shadows)]}
    })
    expect(found).toEqual({weights: [], shadows: []})
  })
}
