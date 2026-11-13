import type {Page} from "@playwright/test"
import {expect, test, watch} from "./support/test"

// The header on a phone, as in the Regent template's phone header: 56px tall with
// the template's 16px side padding, every control at least 44px each way, and the
// places to go and Ask in a Menu that keeps the page behind it out of reach until
// it closes. Found on 29 Oct (the UI audit): the header's side padding was 12px,
// 8px at 320, and the wordmark link was 23px wide. Signed out, the theme switch
// stays off phones (Sean, 16 Oct) and is in the header on a desktop
// (theme_switch.spec.ts walks its presses).

const theme = (page: Page) =>
  page.evaluate(() =>
    document.documentElement.dataset.theme ??
    (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"))

test("on a phone the header is 56px tall and every control 44px each way, and no theme switch", async ({page, isMobile}) => {
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

  // Signed out on a phone there is no theme switch to press.
  await expect(page.getByRole("switch", {name: "Light theme"})).toHaveCount(0)
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
  for (const name of ["Questions", "Sites", "Ask"])
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
  await menu.getByRole("link", {name: "Questions", exact: true}).click()
  await expect(page).toHaveURL(/\/$/)
  await problems.expect()
})

test("on a desktop the places to go are in the header, with the theme switch", async ({page, isMobile}) => {
  test.skip(isMobile, "the desktop header")
  const problems = watch(page)
  await page.goto("/sites")
  const header = page.locator("header.pb-masthead")
  await expect(header.getByRole("navigation", {name: "Patchbay"}).getByRole("link", {name: "Questions"})).toBeVisible()
  await expect(page.getByRole("button", {name: "Menu"})).toBeHidden()
  const before = await theme(page)
  await header.getByRole("switch", {name: "Light theme"}).click()
  await expect.poll(() => theme(page)).not.toBe(before)
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

  // The walk's one report (support/report.exs), opened from its site's list,
  // which no walk posts to: the home page's first screen of posts fills with
  // the posts the walks publish. The site's tool check that page asks for is
  // answered here: it is not what this walk is about.
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({contentType: "application/json", body: JSON.stringify({status: "none", said: "", tools: [], directory: false})}))
  await page.goto("/keyfleet.ai")
  await page.getByRole("link", {name: /not_signed_in/}).first().click()
  await page.getByRole("link", {name: /All questions/}).click()
  await expect(page).toHaveURL(/\/$/)
  await problems.expect()
})
