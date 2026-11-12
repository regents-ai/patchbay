import type {Page} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// The post form says what is wrong with a field under that field: never while
// it is typed, once the field is left, and when a post is turned down. Typing
// takes the line away once the field is right. At 1280, 390 and 320.

const LONG = "The booking tool refuses every date I give it ".repeat(4)

// The site's tool check is answered here, as in draft.spec.ts: it is not what
// these walks are about.
test.beforeEach(async ({page}) => {
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({status: "none", said: "", tools: [], directory: false}),
    }))
})

// A field with its line: the line says something, in view, and the field is
// marked wrong and described by it.
async function expectWrong(page: Page, id: string) {
  const said = page.locator(`#${id}-errors > p`)
  await expect(said).toHaveCount(1)
  await expect(said).not.toBeEmpty()
  await expect(said).toBeInViewport()
  await expect(page.locator(`#${id}`)).toHaveAttribute("aria-invalid", "true")
  await expect(page.locator(`#${id}`)).toHaveAttribute("aria-describedby", new RegExp(`(^| )${id}-errors( |$)`))
}

async function expectRight(page: Page, id: string) {
  await expect(page.locator(`#${id}-errors > p`)).toHaveCount(0)
  await expect(page.locator(`#${id}`)).not.toHaveAttribute("aria-invalid", "true")
  await expect(page.locator(`#${id}`)).not.toHaveAttribute("aria-describedby", new RegExp(`${id}-errors`))
}

test("a title too long is said under it once the field is left, and typing it right takes the line away", async ({page}) => {
  const problems = watch(page)
  await page.goto("/hermes")
  const goal = page.locator("#pb-fix-goal")

  // Typed, not yet left: nothing is said.
  await goal.pressSequentially(LONG.slice(0, 20))
  await goal.fill(LONG)
  await expectRight(page, "pb-fix-goal")

  await page.locator("#pb-fix-site").focus()
  await expectWrong(page, "pb-fix-goal")

  // Still wrong while it is typed shorter; right, and the line goes.
  await goal.fill(LONG.slice(0, 170))
  await expectWrong(page, "pb-fix-goal")
  await goal.fill(LONG.slice(0, 40))
  await expectRight(page, "pb-fix-goal")
  await problems.expect()
})

test("a press with fields left empty says so under each, and asks Patchbay for nothing", async ({page}) => {
  const problems = watch(page)
  const asked: string[] = []
  page.on("request", request => {
    if (request.method() === "POST") asked.push(new URL(request.url()).pathname)
  })
  await page.goto("/hermes")
  await page.locator("[data-pb-preview]").click()
  await expectWrong(page, "pb-fix-goal")
  await expect(page.locator("#pb-fix-site-errors > p")).toHaveCount(1)
  await expect(page.locator("#pb-fix-site")).toHaveAttribute("aria-invalid", "true")
  await expect(page.locator("#pb-fix-goal")).toBeFocused()
  await expect(page.locator("#pb-fix-status")).toBeEmpty()
  expect(asked.filter(path => path.endsWith("/threads") || path === "/threads/preview")).toEqual([])

  // Typing the field right takes its line away; the other keeps its own.
  await page.locator("#pb-fix-goal").fill("Booking tool refuses my date")
  await expectRight(page, "pb-fix-goal")
  await expect(page.locator("#pb-fix-site-errors > p")).toHaveCount(1)
  await problems.expect()
})

test("a preview Patchbay turns down over the title is said under the title", async ({page}) => {
  const problems = watch(page)
  await page.goto("/hermes")
  await page.locator("#pb-fix-goal").fill(LONG)
  await page.locator("#pb-fix-site").fill("keyfleet.ai")
  const answered = page.waitForResponse(response => new URL(response.url()).pathname === "/threads/preview")
  await page.locator("[data-pb-preview]").click()
  await answered
  await expectWrong(page, "pb-fix-goal")
  await expect(page.locator("#pb-fix-goal")).toBeFocused()
  await expect(page.locator("#pb-hero-preview > *")).toHaveCount(0)
  await expect(page.locator("#pb-fix-status")).toBeEmpty()
  await problems.expect()
})

test.describe("signed in", () => {
  test.use(signedIn)

  test("a post Patchbay refuses over the site is said under the site, and changing it takes the line away", async ({page}) => {
    const problems = watch(page)
    await page.goto("/hermes")
    await page.locator("#pb-fix-goal").fill("Booking tool refuses my date")
    await page.locator("#pb-fix-site").fill("not a web address")
    await page.locator("[data-pb-preview]").click()
    const publish = page.locator("[data-pb-post]")
    await expect(publish).toBeVisible()
    await Promise.all([page.waitForEvent("load"), publish.click()])

    await expectWrong(page, "pb-fix-site")
    await expectRight(page, "pb-fix-goal")
    await expect(page.locator("#pb-hero-form .pb-reply-form-problem")).toHaveCount(0)
    await expect(page.locator("#pb-fix-goal")).toHaveValue("Booking tool refuses my date")

    await page.locator("#pb-fix-site").fill("keyfleet.ai")
    await expectRight(page, "pb-fix-site")
    await problems.expect()
  })

  test("too many pictures are said under Pictures as they are chosen, and stop the press", async ({page}) => {
    const problems = watch(page)
    await page.goto("/hermes")
    await page.locator("#pb-fix-goal").fill("Booking tool refuses my date")
    await page.locator("#pb-fix-site").fill("keyfleet.ai")
    await page.locator("#pb-hero-details > summary").click()
    const picture = (name: string) => ({name, mimeType: "image/png", buffer: Buffer.from("a small picture")})
    const pictures = page.locator("#pb-hero-pictures")
    await pictures.setInputFiles(["a.png", "b.png", "c.png", "d.png"].map(picture))
    await expectWrong(page, "pb-hero-pictures")

    // The fields fold away; the press opens them again at the field to fix.
    await page.locator("#pb-hero-details > summary").click()
    await page.locator("[data-pb-preview]").click()
    await expectWrong(page, "pb-hero-pictures")
    await expect(page.locator("#pb-hero-preview > *")).toHaveCount(0)

    await pictures.setInputFiles([picture("a.png")])
    await expectRight(page, "pb-hero-pictures")
    await problems.expect()
  })
})
