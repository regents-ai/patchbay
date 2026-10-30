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

// Narrower than 22.5rem the header has no room for the balance, so the account menu
// shows it, in the header's words, and the row opens the same Buy Credits dialog.
test("on the narrowest phones the balance is in the account menu and opens Buy Credits", async ({page, isMobile}) => {
  test.skip(!isMobile, "only the narrowest phones move the balance")
  const problems = watch(page)
  await page.setViewportSize({width: 320, height: 900})
  await page.goto("/about")
  await ready(page)
  await expect(page.locator("#pb-credits-balance")).toBeHidden()
  await openMenu(page)

  const row = page.locator("#account-menu-credits")
  await expect(row).toBeVisible()
  // The header's words: its balance's name once read, as "0 Credits".
  await expect(page.locator("#pb-credits-balance")).toHaveAttribute("aria-label", /^\S+ Credits$/)
  const words = (await page.locator("#pb-credits-balance").getAttribute("aria-label"))!
  expect(words).toMatch(/^\S+ Credits$/)
  await expect(row).toHaveText(words)
  await expect(row).toHaveAccessibleName(words)
  expect((await row.boundingBox())!.height).toBeGreaterThanOrEqual(44)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320)

  await row.click()
  await expect(menu(page)).toBeHidden()
  await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeHidden()
  await expect(chip(page)).toBeFocused()
  await problems.expect()
})

test("wider than the narrowest phones the balance stays in the header, not the menu", async ({page, isMobile}) => {
  const problems = watch(page)
  const width = isMobile ? 390 : 1280
  await page.setViewportSize({width, height: 900})
  await page.goto("/about")
  await ready(page)
  const balance = page.locator("#pb-credits-balance")
  await expect(balance).toBeVisible()
  // A phone's header keeps the figure and leaves the word out.
  await expect(balance.locator(".pb-credits-unit")).toBeVisible({visible: !isMobile})
  await openMenu(page)
  await expect(page.locator("#account-menu-credits")).toBeHidden()
  await page.keyboard.press("Escape")
  await balance.click()
  await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeVisible()
  await problems.expect()
})

// Found in review on 29 Oct: the header left the word "Credits" out below 900px,
// where the Regent template leaves it out only below 768px. From 768px the balance
// keeps its word, and the header still fits on one line.
test("from 768px the header's balance keeps the word Credits, and the header fits", async ({page, isMobile}) => {
  test.skip(isMobile, "widths a desktop reaches")
  const problems = watch(page)
  for (const [width, word] of [[767, false], [768, true], [899, true], [1099, true]] as const) {
    await page.setViewportSize({width, height: 900})
    await page.goto("/about")
    await ready(page)
    const balance = page.locator("#pb-credits-balance")
    await expect(balance.locator(".pb-credits-unit")).toBeVisible({visible: word})
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
