import {readFileSync} from "node:fs"
import type {Page} from "@playwright/test"
import {expect, namer, signInFile, test} from "./support/test"

// Every page that names the walk's namer fits the screen at every width. Their
// name is 80 characters with no space to break at (sign_in.exs), and report.exs
// gives them a question, their own reply, an agent's answer for them and a reply
// the reader turned away. Where a name has room to wrap it breaks; in a badge it
// ends in an ellipsis.

const named = (): {question: string; id: string} => JSON.parse(readFileSync(signInFile("namer-pages"), "utf8"))

// Opens each address in turn and gives how far each one that is wider than the
// screen reaches past it, read once the page has its styles.
async function wider(page: Page, addresses: string[]) {
  const found: Record<string, number> = {}
  for (const address of addresses) {
    expect((await page.goto(address))?.status(), address).toBe(200)
    await page.waitForLoadState()
    const past = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    )
    if (past > 0) found[address] = past
  }
  return found
}

test.describe("the namer's own pages", () => {
  test.use(namer)

  test("name them and fit the screen", async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    const {question, id} = named()
    const found = await wider(page, [
      "/account",
      "/account/profile",
      "/",
      "/named.com",
      question,
      `/agents/${id}`,
      "/points",
    ])

    // The account menu opens above the page, so the page's width leaves it out:
    // it keeps the name inside itself and stays on the screen.
    await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
    await page.locator("#pb-account-chip").click()
    const menu = page.locator("#account-menu")
    await expect(menu).toBeVisible()
    await expect.poll(() => menu.evaluate(element => element.getAnimations().length)).toBe(0)
    const box = (await menu.boundingBox())!
    const fitsMenu = {
      onScreen: box.x >= 0 && box.x + box.width <= page.viewportSize()!.width,
      inside: await menu.evaluate(element => element.scrollWidth <= element.clientWidth),
    }

    expect({found, fitsMenu, errors}).toEqual({found: {}, fitsMenu: {onScreen: true, inside: true}, errors: []})
  })
})

test.describe("the moderators' pages", () => {
  test.use({storageState: signInFile("moderator")})

  test("name the namer and fit the screen", async ({page}) => {
    const errors: string[] = []
    page.on("pageerror", error => errors.push(error.message))
    const found = await wider(page, ["/admin/people", `/admin/people/${named().id}`, "/moderation"])
    expect({found, errors}).toEqual({found: {}, errors: []})
  })
})
