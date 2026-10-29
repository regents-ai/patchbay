import type {Page} from "@playwright/test"
import {expect, test, watch} from "./support/test"

// The header on a phone, as in the Regent template's phone header: 56px tall with
// the template's 16px side padding, every control at least 44px each way, and the
// places to go and Ask in a Menu that keeps the page behind it out of reach until
// it closes. Found on 29 Oct (the UI audit): the header's side padding was 12px,
// 8px at 320, and the wordmark link was 23px wide. The theme switch stays off
// phones (Sean, 16 Oct) and is in the header on a desktop.

const theme = (page: Page) =>
  page.evaluate(() =>
    document.documentElement.dataset.theme ??
    (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"))

test("on a phone the header is 56px tall, every control 44px each way, and no theme switch", async ({page, isMobile}) => {
  test.skip(!isMobile, "the phone header")
  const problems = watch(page)
  await page.goto("/sites")
  const header = page.locator("header.pb-masthead")
  const box = (await header.boundingBox())!
  expect(box.height).toBeLessThanOrEqual(56)
  expect(await header.evaluate(element => getComputedStyle(element).paddingInlineStart)).toBe("16px")
  for (const control of await header.locator("a:visible, button:visible").all()) {
    const size = (await control.boundingBox())!
    const name = await control.evaluate(element => element.outerHTML.slice(0, 80))
    expect(size.height, name).toBeGreaterThanOrEqual(44)
    expect(size.width, name).toBeGreaterThanOrEqual(44)
    expect(size.x + size.width).toBeLessThanOrEqual(box.x + box.width)
  }

  // Nowhere on the page, header or footer, is there a theme switch to press.
  await expect(page.locator("[data-pb-theme-toggle]:visible")).toHaveCount(0)
  await problems.expect()
})

test("on a phone the Menu holds the places to go and keeps the page out of reach", async ({page, isMobile}) => {
  test.skip(!isMobile, "the phone header")
  const problems = watch(page)
  await page.goto("/sites")
  const button = page.getByRole("button", {name: "Menu"})
  await button.click()
  const menu = page.getByRole("dialog", {name: "Menu"})
  await expect(menu).toBeVisible()
  for (const name of ["Questions", "Sites", "Offers", "Ask"])
    await expect(menu.getByRole("link", {name, exact: true})).toBeVisible()
  await expect(menu.getByRole("link", {name: "Sites", exact: true})).toHaveAttribute("aria-current", "page")

  // The page behind is out of reach: a press there lands on the menu's shade, and
  // the keyboard never leaves the menu.
  const behind = {x: 40, y: page.viewportSize()!.height - 40}
  expect(await page.evaluate(([x, y]) => document.elementFromPoint(x, y)?.id, [behind.x, behind.y])).toBe("pb-nav-menu")
  for (let press = 0; press < 6; press++) {
    await page.keyboard.press("Tab")
    expect(await page.evaluate(() => document.activeElement === document.body || document.activeElement?.closest("#pb-nav-menu") !== null)).toBe(true)
  }

  await page.keyboard.press("Escape")
  await expect(menu).toBeHidden()
  await expect(button).toBeFocused()

  // A press on the shade closes it too, and a place in it opens its page.
  await button.click()
  await page.mouse.click(behind.x, behind.y)
  await expect(menu).toBeHidden()
  await button.click()
  await menu.getByRole("link", {name: "Offers", exact: true}).click()
  await expect(page).toHaveURL(/\/offers$/)
  await problems.expect()
})

test("on a desktop the places to go are in the header, with the theme switch", async ({page, isMobile}) => {
  test.skip(isMobile, "the desktop header")
  const problems = watch(page)
  await page.goto("/sites")
  const header = page.locator("header.pb-masthead")
  await expect(header.getByRole("navigation", {name: "Patchbay"}).getByRole("link", {name: "Questions"})).toBeVisible()
  await expect(page.getByRole("button", {name: "Menu"})).toBeHidden()
  await expect(page.locator("[data-pb-theme-toggle]:visible")).toHaveCount(1)
  const before = await theme(page)
  await header.locator(".pb-theme-toggle").click()
  expect(await theme(page)).not.toBe(before)
  await problems.expect()
})

// Found on 29 Oct (the UI audit): the header's Questions opened a list of two
// "open questions" while the home page listed twenty-two, and a thread's "All
// questions" led to the home page. Questions now means the home page's list
// everywhere.
test("Questions in the header and a thread's All questions open the same list", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto("/sites")
  if (isMobile) await page.getByRole("button", {name: "Menu"}).click()
  const nav = page.getByRole(isMobile ? "dialog" : "banner", {name: isMobile ? "Menu" : undefined})
  await nav.getByRole("link", {name: "Questions", exact: true}).click()
  await expect(page).toHaveURL(/\/$/)
  const feed = page.locator(".pb-feed-tabs")
  await expect(feed).toBeVisible()

  // The walk's one report (support/report.exs), opened from that list.
  await page.getByRole("link", {name: /not_signed_in/}).first().click()
  await page.getByRole("link", {name: /All questions/}).click()
  await expect(page).toHaveURL(/\/$/)
  await problems.expect()
})
