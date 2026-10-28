import {expect, signedIn, test, watch} from "./support/test"

// Found on 28 Oct (the design chief's live check): at 390 wide, a tip in the page
// (an agent's card, the Offers question mark, the Wallet Bench filter) drew over the
// header and over the side panel opened from it, because the page content made no
// stacking place of its own. The page content is one place now, under the header
// and the side panel; the motion lab's drawer, sheet and note are lifted above the
// whole page by the browser, as a window is.

// What sits at the centre of a box: inside which of the named parts it lands.
const landsIn = (page: import("@playwright/test").Page, box: {x: number; y: number; width: number; height: number}, selector: string) =>
  page.evaluate(
    ({x, y, selector}) => document.elementFromPoint(x, y)?.closest(selector) !== null,
    {x: box.x + box.width / 2, y: box.y + box.height / 2, selector},
  )

test.describe("signed in, at 390 wide", () => {
  test.use(signedIn)

  test("a tip in the page stays under the open side panel", async ({page}) => {
    const problems = watch(page)
    await page.setViewportSize({width: 390, height: 844})
    await page.goto("/account")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

    const aside = page.locator("#shell-aside")
    if (!(await aside.isVisible())) await page.locator("#pb-account-chip").click()
    await expect(aside).toBeVisible()
    await expect
      .poll(() => page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length))
      .toBe(0)

    // A tip shown at the top of the page content, where the open panel lies over it.
    await page.evaluate(() => {
      const host = document.createElement("span")
      host.className = "pb-offers-tip-host"
      host.innerHTML =
        '<span class="pb-offers-tip"><span id="walk-tip" role="tooltip" class="pb-offers-tip-text" style="display: block">A tip</span></span>'
      document.querySelector("#pb-content")!.prepend(host)
    })
    const tip = (await page.locator("#walk-tip").boundingBox())!
    const panel = (await aside.boundingBox())!
    expect(tip.x + tip.width / 2).toBeGreaterThan(panel.x)
    expect(tip.x + tip.width / 2).toBeLessThan(panel.x + panel.width)
    expect(tip.y + tip.height / 2).toBeGreaterThan(panel.y)

    expect(await landsIn(page, tip, "#shell-aside")).toBe(true)
    await problems.expect()
  })
})

test("the motion lab's drawer opens over the header", async ({page}) => {
  const problems = watch(page)
  await page.goto("/animations")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  // Opened from the keyboard, so it is there at once.
  await page.getByRole("button", {name: "Open the drawer"}).press("Enter")
  const drawer = page.locator("#lab-drawer")
  await expect(drawer).toBeVisible()
  // The header scrolls with the page; the drawer stays where it opened.
  await page.evaluate(() => window.scrollTo(0, 0))

  const header = (await page.locator(".pb-frame > :first-child").boundingBox())!
  const box = (await drawer.boundingBox())!
  const overlap = {x: box.x, y: header.y, width: Math.min(box.width, header.width), height: header.height}
  expect(await landsIn(page, overlap, "#lab-drawer")).toBe(true)

  await page.keyboard.press("Escape")
  await expect(drawer).toBeHidden()
  await problems.expect()
})
