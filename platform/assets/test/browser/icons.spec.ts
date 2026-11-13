import {readFileSync} from "node:fs"
import {type Locator, type Page} from "@playwright/test"
import {press} from "./support/motion"
import {expect, signedIn, signInFile, test, watch} from "./support/test"

// An icon button draws its icon in the middle of its square, within half a point
// across and down: the follow bell at rest, followed and back at rest, each after
// its swing has settled, and the copy and open icons beside the reader's name and
// a reply's heart. Each width opens its own question (support/report.exs).

const question = (): string =>
  JSON.parse(readFileSync(signInFile("presses"), "utf8"))[test.info().project.name.replace(/\W+/g, "-")].question

const threadConnected = (page: Page) =>
  page.locator("[data-phx-session].phx-connected:has(#pb-thread)").waitFor({state: "attached"})

// The bell hangs straight again: its swing is over and nothing moves it.
const hangs = (icon: Locator) =>
  expect
    .poll(() => icon.evaluate(svg => getComputedStyle(svg).transform === "none" && svg.getAnimations().length === 0))
    .toBe(true)

async function expectCentred(button: Locator, what: string) {
  const {across, down, width, height} = await button.evaluate(button => {
    const icon = [...button.querySelectorAll("svg")].find(svg => svg.checkVisibility({opacityProperty: true}))!
    const square = button.getBoundingClientRect()
    const drawn = icon.getBoundingClientRect()
    return {
      across: drawn.left + drawn.width / 2 - (square.left + square.width / 2),
      down: drawn.top + drawn.height / 2 - (square.top + square.height / 2),
      width: square.width,
      height: square.height,
    }
  })
  expect(Math.abs(across), `${what}: across`).toBeLessThanOrEqual(0.5)
  expect(Math.abs(down), `${what}: down`).toBeLessThanOrEqual(0.5)
  return {width, height}
}

// Signed out, the bell follows for this browser alone, so no other check presses
// the same bell.
test("the follow bell stays in the middle of its square, followed or not", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto(question())
  await threadConnected(page)
  const bell = page.locator(".pb-follow-bell")
  const icon = bell.locator(".rg-icon")

  const square = await expectCentred(bell, "the bell at rest")
  expect(Math.min(square.width, square.height), "the bell's square").toBeGreaterThanOrEqual(44)

  await press(bell, isMobile)
  await expect(bell).toHaveAttribute("aria-pressed", "true")
  await hangs(icon)
  await expectCentred(bell, "the bell followed")

  await bell.focus()
  await page.keyboard.press("Enter")
  await expect(bell).toHaveAttribute("aria-pressed", "false")
  await hangs(icon)
  await expectCentred(bell, "the bell at rest again")
  await problems.expect()
})

test.describe("signed in", () => {
  test.use(signedIn)

  // Read only: other checks press this question's hearts and bell.
  test("the copy, open and heart icons sit in the middle of their squares", async ({page}) => {
    await page.goto(question())
    await threadConnected(page)
    const replyAs = page.locator(".pb-reply-as")
    await expectCentred(replyAs.locator(".rg-copy--icon"), "the copy icon")
    await expectCentred(replyAs.locator(".rg-address__explorer"), "the open icon")
    // The reply the reader's own agent wrote: nobody likes it, so its heart has no
    // count beside it.
    const proxyReply = page.locator(".rg-discussion__post", {has: page.locator(".pb-badge-for")})
    await expectCentred(proxyReply.locator(".rg-discussion__heart"), "the heart")
  })
})
