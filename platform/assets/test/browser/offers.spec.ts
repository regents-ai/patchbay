import {readFileSync} from "node:fs"
import type {Locator, Page} from "@playwright/test"
import {expect, signInFile, test, watch} from "./support/test"

// Paid offers on the walk's own market (support/offers.exs): openai.com's
// placement, its three slots bought, and a question on its board.
//
// The home page's Bids strip holds to the foot of the screen in a room of its
// own under the page, so the page's end is never under it; it stops while a
// pointer or the keyboard is in it, and stands still as a row that scrolls for
// a reader who asked for less motion. On /sites a site showing an offer is
// marked Sponsored, with a line as long as the share of its time left, and its
// row keeps its shape. A question's offers are each one line that opens in
// place to its text, with or without the page's script.

const question = () => JSON.parse(readFileSync(signInFile("offers"), "utf8")).question as string

const ticker = (page: Page) => page.locator("#pb-ticker")
const track = (page: Page) => ticker(page).locator(".pb-ticker-track")
const playState = (locator: Locator) => locator.evaluate(el => getComputedStyle(el).animationPlayState)

// How far the bright line under the badge reaches, from 0 to 1, as drawn now.
const lineLeft = (badge: Locator) =>
  badge
    .locator(".pb-directory-timer")
    .evaluate(el => new DOMMatrix(getComputedStyle(el, "::before").transform).a)

test.describe("the home page's Bids strip", () => {
  test("holds to the foot of the screen and never covers the page's end", async ({page}) => {
    const problems = watch(page)
    await page.goto("/")
    const strip = ticker(page)
    await expect(strip).toBeVisible()
    await expect(strip.locator(".pb-ticker-list").first().locator(".pb-ticker-item")).toHaveCount(3)

    const viewport = page.viewportSize()!
    const box = (await strip.boundingBox())!
    expect(Math.round(box.y + box.height), "the strip sits on the foot of the screen").toBe(viewport.height)

    // At the end of the page the strip sits under the page's own content.
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
    await expect
      .poll(() =>
        page.evaluate(() => {
          const main = document.querySelector("#patchbay-home")!.getBoundingClientRect()
          const strip = document.querySelector("#pb-ticker")!.getBoundingClientRect()
          return main.bottom <= strip.top + 1
        }),
      )
      .toBe(true)
    await problems.expect()
  })

  test("stops under the pointer and the keyboard, and only the shown copy takes focus", async ({page, isMobile}) => {
    await page.goto("/")
    await expect(ticker(page)).toBeVisible()
    expect(await playState(track(page))).toBe("running")

    if (!isMobile) {
      await ticker(page).locator(".pb-ticker-window").hover()
      await expect.poll(() => playState(track(page))).toBe("paused")
      await page.mouse.move(0, 0)
      await expect.poll(() => playState(track(page))).toBe("running")
    }

    const [shown, copy] = [track(page).locator(".pb-ticker-list").nth(0), track(page).locator(".pb-ticker-list").nth(1)]
    await shown.locator("a").first().focus()
    await expect(shown.locator("a").first()).toBeFocused()
    await expect.poll(() => playState(track(page))).toBe("paused")

    // Tab walks the shown links and leaves the strip, never entering the copy.
    for (let n = 1; n < 3; n++) {
      await page.keyboard.press("Tab")
      await expect(shown.locator("a").nth(n)).toBeFocused()
    }
    await page.keyboard.press("Tab")
    expect(await copy.evaluate(list => list.contains(document.activeElement))).toBe(false)
  })

  test("is a still row that scrolls for a reader who asked for less motion", async ({page}) => {
    const problems = watch(page)
    await page.emulateMedia({reducedMotion: "reduce"})
    await page.goto("/")
    await expect(ticker(page)).toBeVisible()

    expect(await track(page).evaluate(el => el.getAnimations().length)).toBe(0)
    await expect(track(page).locator(".pb-ticker-list").nth(1)).toBeHidden()
    const window = ticker(page).locator(".pb-ticker-window")
    expect(await window.evaluate(el => getComputedStyle(el).overflowX)).toBe("auto")
    await problems.expect()
  })

  test("a purchase opens its slot on the Offers page", async ({page}) => {
    await page.goto("/")
    const link = track(page).locator(".pb-ticker-list").first().locator("a").first()
    const href = (await link.getAttribute("href"))!
    expect(href).toMatch(/^\/offers\?placement=1&slot=\d#placement-1-slot-\d$/)
    expect((await page.goto(href))?.status()).toBe(200)
  })
})

test.describe("the sites list", () => {
  test("marks the site showing an offer, with a line as long as its time left", async ({page}) => {
    const problems = watch(page)
    expect((await page.goto("/sites"))?.status()).toBe(200)
    // Only openai.com's forum shows offers; every row that leads to it is marked
    // (developers.openai.com is listed too, and its forum is openai.com's).
    const row = page.locator("tr[id='directory-openai.com']")
    await expect(row.locator(".pb-directory-sponsored")).toBeVisible()
    const marked = page.locator("tr", {has: page.locator(".pb-directory-sponsored")})
    const forums = await marked.locator(".pb-directory-forum").evaluateAll(links => links.map(a => a.getAttribute("href")))
    expect(forums.length).toBeGreaterThan(0)
    expect(new Set(forums)).toEqual(new Set(["/openai.com"]))
    const badge = row.locator(".pb-directory-sponsored")
    await expect(badge).toBeVisible()
    await expect(badge).toContainText("Sponsored")

    // Bought 18 hours into a day-long term: a quarter left, running down.
    expect(await lineLeft(badge)).toBeCloseTo(0.25, 1)

    // On a wide page the row keeps its shape: View Forum still comes right
    // after the address, and the badge sits on its line, no taller than it. A
    // narrow page leaves the address out and puts the badge on the line under
    // View Forum, lined up with it.
    const forum = (await row.locator(".pb-directory-forum > span").first().boundingBox())!
    const mark = (await row.locator(".pb-directory-badge").boundingBox())!
    const url = row.locator(".pb-directory-url")
    if (await url.isVisible()) {
      const address = (await url.boundingBox())!
      expect(forum.x).toBeGreaterThanOrEqual(address.x + address.width)
      expect(forum.x - (address.x + address.width)).toBeLessThan(24)
      const whole = (await badge.boundingBox())!
      expect(whole.height).toBeLessThanOrEqual(forum.height + 1)
      expect(whole.y).toBeGreaterThanOrEqual(forum.y - 1)
      expect(whole.y + whole.height).toBeLessThanOrEqual(forum.y + forum.height + 1)
    } else {
      expect(Math.abs(mark.x - forum.x)).toBeLessThan(1)
      expect(mark.y).toBeGreaterThanOrEqual(forum.y + forum.height - 1)
    }
    await problems.expect()
  })

  test("holds the line still for a reader who asked for less motion", async ({page}) => {
    await page.emulateMedia({reducedMotion: "reduce"})
    await page.goto("/sites")
    const badge = page.locator("tr[id='directory-openai.com'] .pb-directory-sponsored")
    await expect(badge).toBeVisible()
    expect(await lineLeft(badge)).toBeCloseTo(0.25, 1)
    expect(
      await badge.locator(".pb-directory-timer").evaluate(el => getComputedStyle(el, "::before").animationName),
    ).toBe("none")
  })
})

test.describe("a question's offers", () => {
  test("each opens in place to its text", async ({page}) => {
    const problems = watch(page)
    expect((await page.goto(question()))?.status()).toBe(200)
    const entries = page.locator("#pb-paid-offers details.pb-paid-entry")
    await expect(entries).toHaveCount(3)
    const entry = entries.first()
    const text = entry.locator(".pb-paid-body")
    await expect(text).toBeHidden()

    await entry.locator("summary").click()
    await expect(text).toBeVisible()
    await expect(entry.locator(".pb-paid-link")).toHaveAttribute("rel", "sponsored noopener")

    // And from the keyboard.
    const next = entries.nth(1)
    await next.locator("summary").focus()
    await page.keyboard.press("Enter")
    await expect(next.locator(".pb-paid-body")).toBeVisible()
    await problems.expect()
  })

  test.describe("without the page's script", () => {
    test.use({javaScriptEnabled: false})

    test("an offer still opens to its text", async ({page}) => {
      await page.goto(question())
      const entry = page.locator("#pb-paid-offers details.pb-paid-entry").first()
      await expect(entry.locator(".pb-paid-body")).toBeHidden()
      await entry.locator("summary").click()
      await expect(entry.locator(".pb-paid-body")).toBeVisible()
    })
  })
})
