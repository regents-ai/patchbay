import type {Page} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// The account menu, opened by the account's picture and name at the top right of
// every page, as in the Regent template. The walk's person has four agents
// (support/sign_in.exs) and none has been active, so the menu shows the three paired
// last and leaves out Spare Agent, paired first. Manage beside the heading opens
// this site's own Agents page. With a mouse it shows while the pointer is
// over the list or a key has moved into it, and the rows never move when it does; on
// the touch phone it always shows, 44 px tall.
test.use(signedIn)

const menu = (page: Page) => page.locator("#account-menu")
const chip = (page: Page) => page.locator("#pb-account-chip")

// The header's live part answers once it has connected, as it has for a person by
// the time they reach for it.
async function ready(page: Page) {
  await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
}

// Opened, and done dropping in, so what is measured is where it rests.
async function openMenu(page: Page) {
  await chip(page).click()
  await expect(menu(page)).toBeVisible()
  await expect.poll(() => menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
}

test("the account menu shows three agents and Manage", async ({page, hasTouch}) => {
  const problems = watch(page)
  await page.goto("/about")
  await ready(page)
  await openMenu(page)
  const agents = page.locator("#account-menu-agents")

  await expect(agents.getByRole("listitem")).toHaveCount(3)
  await expect(agents).not.toContainText("Spare Agent")

  const manage = agents.getByRole("link", {name: "Manage your agents"})
  await expect(manage).toHaveText("Manage")
  await expect(manage).toHaveAttribute("href", "/account/agents")
  const opacity = () => manage.evaluate(link => getComputedStyle(link).opacity)

  if (hasTouch) {
    await expect.poll(opacity).toBe("1")
    expect((await manage.boundingBox())!.height).toBeGreaterThanOrEqual(44)
  } else {
    // Where the rows sit inside the menu.
    const rows = () =>
      agents.getByRole("list").evaluate(list => {
        const box = list.getBoundingClientRect()
        return {top: box.top - list.closest("section")!.getBoundingClientRect().top, height: box.height}
      })
    const before = await rows()
    await agents.getByRole("heading", {name: "Your agents"}).hover()
    await expect.poll(opacity).toBe("1")
    expect(await rows()).toEqual(before)

    // Off the list, still inside the menu, so it stays open.
    await menu(page).locator(".rg-account-menu__name").hover()
    await expect.poll(opacity).toBe("0")
    await manage.focus()
    await expect.poll(opacity).toBe("1")
  }
  await manage.click()
  await expect(page).toHaveURL(/\/account\/agents$/)
  await expect(page.locator("#account-agents")).toBeVisible()
  await expect(menu(page)).toBeHidden()
  await problems.expect()
})

// Found on 21 Oct (Sean), when the account's things were in a panel down the right:
// it slid in beside the header and cut its bottom line short. The menu hangs under
// the button instead, and the header and the page keep their whole width.
test("the account menu hangs under its button, the page keeps its width, and Escape closes it", async ({page, isMobile}) => {
  const problems = watch(page)
  for (const width of isMobile ? [390, 320] : [1280, 2000]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/about")
    await ready(page)
    const header = page.locator(".pb-frame > :first-child")
    const content = page.locator("#pb-content")
    const closed = {header: (await header.boundingBox())!, content: (await content.boundingBox())!}
    await openMenu(page)

    const button = (await chip(page).boundingBox())!
    const box = (await menu(page).boundingBox())!
    // Below the button, inside the screen, its right edge near the button's.
    expect(box.y).toBeGreaterThanOrEqual(button.y + button.height)
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(width)
    if (!isMobile) expect(Math.abs(box.x + box.width - (button.x + button.width))).toBeLessThan(2)
    expect(await header.boundingBox()).toEqual(closed.header)
    expect(await content.boundingBox()).toEqual(closed.content)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)

    await menu(page).getByRole("link", {name: "Manage Account"}).focus()
    await page.keyboard.press("Escape")
    await expect(menu(page)).toBeHidden()
    await expect(chip(page)).toBeFocused()
  }
  await problems.expect()
})

test("the account menu opens from the keyboard, is named for the person, and a press outside closes it", async ({page}) => {
  const problems = watch(page)
  await page.goto("/about")
  await ready(page)
  await chip(page).focus()
  await page.keyboard.press("Enter")
  await expect(menu(page)).toBeVisible()
  await expect(menu(page)).toHaveRole("region")
  await expect(menu(page)).toHaveAccessibleName(await page.locator(".pb-account-name").innerText())
  // A press beside the menu, or below it where it spans a phone's screen.
  const box = (await menu(page).boundingBox())!
  await page.mouse.click(box.x > 40 ? box.x / 2 : box.x + box.width / 2, box.y + box.height + 20)
  await expect(menu(page)).toBeHidden()
  await problems.expect()
})

test("asked for less motion, the account menu appears at once", async ({page}) => {
  const problems = watch(page)
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.goto("/about")
  await ready(page)
  await chip(page).click()
  await expect(menu(page)).toBeVisible()
  expect(await menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
  await problems.expect()
})

test("Manage Account opens this site's Account page and the menu closes", async ({page}) => {
  const problems = watch(page)
  // From a live page and from a page with no live part of its own.
  for (const start of ["/offers", "/about"]) {
    await page.goto(start)
    await ready(page)
    await openMenu(page)
    await expect(menu(page).getByRole("button", {name: "Sign out"})).toBeVisible()
    await menu(page).getByRole("link", {name: "Manage Account"}).click()
    await expect(page).toHaveURL(/\/account$/)
    await expect(page.locator("#account-identity")).toBeVisible()
    await expect(menu(page)).toBeHidden()
  }
  await problems.expect()
})

test("Pair New Agent in the menu lands on the Agents page's pairing box", async ({page}) => {
  const problems = watch(page)
  await page.goto("/about")
  await ready(page)
  await openMenu(page)
  await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
  await expect(page).toHaveURL(/\/account\/agents#account-pairing$/)
  await expect(menu(page)).toBeHidden()
  const pairing = page.locator("#account-pairing")
  await expect(pairing).toBeInViewport()
  // The keyboard starts on the agent choice.
  await expect(pairing.getByRole("radio").first()).toBeFocused()

  // Pressed again from the same address after scrolling away, it moves there again.
  await page.evaluate(() => window.scrollTo({top: 0}))
  await expect(pairing.getByRole("heading", {name: "Pair New Agent"})).not.toBeInViewport()
  await ready(page)
  await openMenu(page)
  await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
  await expect(menu(page)).toBeHidden()
  await expect(pairing).toBeInViewport()
  await expect(pairing.getByRole("radio").first()).toBeFocused()

  // The Agents page's own Pair New Agent, under the agents, goes to the same box.
  await page.evaluate(() => window.scrollTo({top: 0}))
  await page.locator("#account-agents").getByRole("link", {name: "Pair New Agent"}).click()
  await expect(pairing).toBeInViewport()
  await expect(pairing.getByRole("radio").first()).toBeFocused()
  await problems.expect()
})

// The Credits balance is the account menu's own row at every width, under the
// wallet (PB-66); the header keeps only the logo and the account button. Walked on
// the desktop at 1280 and the touch phones at 390 and 320.
test("the account menu shows the balance and opens Buy Credits", async ({page, viewport}) => {
  const problems = watch(page)
  await page.goto("/about")
  await ready(page)
  await expect(page.locator("header.pb-masthead")).not.toContainText("Credits", {useInnerText: true})
  await openMenu(page)

  const row = page.locator("#account-menu-credits")
  await expect(row).toBeVisible()
  // Its name once read, as "0 Credits", is what it shows.
  await expect(row).toHaveAttribute("aria-label", /^\S+ Credits$/)
  const words = (await row.getAttribute("aria-label"))!
  await expect(row).toHaveText(words)
  await expect(row).toHaveAccessibleName(words)
  expect((await row.boundingBox())!.height).toBeGreaterThanOrEqual(44)

  // Straight under the picture, name and wallet, above the agents.
  const who = (await menu(page).locator(".rg-account-menu__who").boundingBox())!
  const agents = (await page.locator("#account-menu-agents").boundingBox())!
  const box = (await row.boundingBox())!
  expect(box.y).toBeGreaterThanOrEqual(who.y + who.height - 1)
  expect(box.y + box.height).toBeLessThanOrEqual(agents.y + 1)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport!.width)

  await row.click()
  await expect(menu(page)).toBeHidden()
  await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeHidden()
  await expect(chip(page)).toBeFocused()
  await problems.expect()
})

// Every control in the header stays inside it, on one line, at the widths a desktop
// reaches.
test("the header fits on one line from 767px", async ({page, isMobile}) => {
  test.skip(isMobile, "widths a desktop reaches")
  const problems = watch(page)
  for (const width of [767, 768, 899, 1099]) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/about")
    await ready(page)
    const header = (await page.locator("header.pb-masthead").boundingBox())!
    for (const control of await page.locator("header.pb-masthead").locator("a:visible, button:visible").all()) {
      const box = (await control.boundingBox())!
      expect(box.x + box.width, `${width}px`).toBeLessThanOrEqual(header.x + header.width)
      expect(box.y + box.height, `${width}px, one line`).toBeLessThanOrEqual(header.y + header.height)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  }
  await problems.expect()
})
