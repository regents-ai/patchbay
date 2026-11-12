import type {Page} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// The light and dark switch (PatchbayWeb.ThemeSwitch.theme_toggle/1), as in the
// Regent template. It is a real switch, on for the light theme: a press, Space or
// Enter turns the page's theme, each one once, and the choice holds over a reload
// and a live page change. Signed in it is a row of the account menu, which keeps
// its size whichever way the switch is turned, and opening the menu moves nothing
// on the page. With no account menu it sits in the header.

const menu = (page: Page) => page.locator("#account-menu")

// The theme on screen: the page's own once chosen, otherwise the device's.
const showing = (page: Page) =>
  page.evaluate(() => {
    const theme = document.documentElement.dataset.theme
    if (theme === "light" || theme === "dark") return theme
    return matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"
  })

const stated = (page: Page) => page.evaluate(() => document.documentElement.dataset.theme)

test.describe("signed in", () => {
  test.use(signedIn)

  const toggle = (page: Page) => menu(page).getByRole("switch", {name: "Light theme"})

  // The header's live part answers once it has connected, as it has for a person
  // by the time they reach for it.
  async function ready(page: Page) {
    await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
  }

  // Opened, and done dropping in, so what is measured is where it rests.
  async function openMenu(page: Page) {
    await page.locator("#pb-account-chip").click()
    await expect(menu(page)).toBeVisible()
    await expect.poll(() => menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
  }

  // The switch says what the page shows: on for light, off for dark.
  async function expectTheme(page: Page, theme: "light" | "dark") {
    await expect.poll(() => showing(page)).toBe(theme)
    await expect(toggle(page)).toHaveAttribute("aria-checked", String(theme === "light"))
  }

  const size = async (page: Page) => {
    const box = (await menu(page).boundingBox())!
    return {width: box.width, height: box.height}
  }

  test("the account menu's theme switch turns the theme by press and by key, and the choice holds", async ({page, hasTouch}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)

    // The account menu, closed or open, is the only place the switch is.
    await expect(page.getByRole("switch", {name: "Light theme", includeHidden: true})).toHaveCount(1)

    const content = page.locator("#pb-content")
    const before = await content.boundingBox()
    await openMenu(page)
    expect(await content.boundingBox()).toEqual(before)
    if (hasTouch) expect((await toggle(page).boundingBox())!.height).toBeGreaterThanOrEqual(44)

    const first = await showing(page)
    const other = first === "light" ? "dark" : "light"
    await expectTheme(page, first)
    const opened = await size(page)

    await toggle(page).click()
    await expectTheme(page, other)
    await expect(menu(page)).toBeVisible()
    expect(await size(page)).toEqual(opened)

    await toggle(page).focus()
    await page.keyboard.press("Space")
    await expectTheme(page, first)
    await page.keyboard.press("Enter")
    await expectTheme(page, other)
    expect(await size(page)).toEqual(opened)

    await page.reload()
    await ready(page)
    await expect.poll(() => stated(page)).toBe(other)
    await openMenu(page)
    await expectTheme(page, other)

    // Manage Account is a live page change: the document stays and restates its theme.
    await page.evaluate(() => void ((window as {pbStayed?: boolean}).pbStayed = true))
    await menu(page).getByRole("link", {name: "Manage Account"}).click()
    await expect(page).toHaveURL(/\/account$/)
    expect(await page.evaluate(() => (window as {pbStayed?: boolean}).pbStayed)).toBe(true)
    await expect.poll(() => stated(page)).toBe(other)
    await openMenu(page)
    await expectTheme(page, other)
    await problems.expect()
  })
})

// Signed out there is no account menu, so on a desktop the switch sits in the
// header: of a page no live view draws, and of a live page. Each press turns it
// once. It stays off phones signed out (Sean, 16 Oct).
test.describe("signed out", () => {
  for (const path of ["/sites", "/offers"]) {
    test(`the header's theme switch on ${path} turns the theme once a press, and the choice holds`, async ({page, isMobile}) => {
      test.skip(isMobile, "signed out, a phone has no theme switch")
      const problems = watch(page)
      await page.goto(path)
      await expect(page.locator("[data-phx-session].phx-connected").first()).toBeAttached()
      const toggle = page.getByRole("switch", {name: "Light theme"})
      await expect(toggle).toHaveCount(1)
      await expect(page.locator("header.pb-masthead").getByRole("switch")).toBeVisible()

      const first = await showing(page)
      const other = first === "light" ? "dark" : "light"
      await expect(toggle).toHaveAttribute("aria-checked", String(first === "light"))

      await toggle.click()
      await expect.poll(() => showing(page)).toBe(other)
      await expect(toggle).toHaveAttribute("aria-checked", String(other === "light"))

      await toggle.focus()
      await page.keyboard.press("Space")
      await expect.poll(() => showing(page)).toBe(first)
      await expect(toggle).toHaveAttribute("aria-checked", String(first === "light"))
      await page.keyboard.press("Enter")
      await expect.poll(() => showing(page)).toBe(other)
      await expect(toggle).toHaveAttribute("aria-checked", String(other === "light"))

      await page.reload()
      await expect.poll(() => stated(page)).toBe(other)
      await expect(toggle).toHaveAttribute("aria-checked", String(other === "light"))
      await problems.expect()
    })
  }
})
