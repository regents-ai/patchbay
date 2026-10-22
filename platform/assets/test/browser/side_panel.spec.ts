import {expect, signedIn, test, watch} from "./support/test"

// Found on 21 Oct (Sean): the side panel slid in beside the header, so the line
// under the panel's short top bar stopped partway down the taller header. The
// header runs the whole width, over the panel; the panel opens under the header's
// bottom line, and the page never scrolls sideways.
test.use(signedIn)

test("the side panel opens under the header, which keeps its whole width", async ({page, isMobile}) => {
  const problems = watch(page)
  for (const width of isMobile ? [page.viewportSize()!.width] : [1280, 2000]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/account")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    const headerRow = page.locator(".pb-frame > :first-child")
    const aside = page.locator("#shell-aside")
    if (await aside.isVisible()) await page.locator("#pb-account-chip").click()
    await expect(aside).toBeHidden()
    const closed = (await headerRow.boundingBox())!

    await page.locator("#pb-account-chip").click()
    await expect(aside).toBeVisible()
    // Measured once the panel has finished opening.
    const moving = () =>
      page.evaluate(() => document.getAnimations().filter(a => a instanceof CSSTransition).length)
    await expect.poll(moving).toBe(0)

    const header = (await headerRow.boundingBox())!
    const panel = (await aside.boundingBox())!
    expect(header.width).toBeCloseTo(closed.width, 0)
    expect(panel.y).toBeCloseTo(header.y + header.height, 0)
    expect(panel.x + panel.width).toBeGreaterThan(header.x)
    expect(panel.x).toBeLessThan(header.x + header.width)
    if (!isMobile) expect(panel.x + panel.width).toBeCloseTo(header.x + header.width, 0)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)

    await page.locator("#pb-account-chip").click()
    await expect(aside).toBeHidden()
  }
  await problems.expect()
})
