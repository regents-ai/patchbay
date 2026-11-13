import type {Page} from "@playwright/test"
import {expect, test} from "./support/test"

// The home page's activity strip (PatchbayWeb.Forum.BoardHTML, hooks/activity_pulse.ts):
// rows of small squares the server draws still, which the GPU draws again once it
// can, and which a wave of colour crosses once each time a post arrives in the
// page's live list (`posts:arrived`, sent here as the live list sends it). It opens
// the page at 1280 on a desktop and at 390 and 320 on a phone with the GPU on, and
// asks that the page lived, the strip drew, a wave ran and ended, another list's
// arrival changed nothing, a new theme repainted it, the heap stayed small and
// nothing reaches past the screen's edge. Then the two ways a visitor keeps the
// still squares: less motion asked for, and a browser without WebGPU.
test.use({launchOptions: {args: ["--enable-unsafe-webgpu", "--enable-gpu"]}})

// The page's script heap: far above what one small strip needs.
const HEAP_CEILING = 64 * 1024 * 1024

const strip = (page: Page) => page.locator("#pb-activity-pulse")

const arrive = (page: Page, list: string) =>
  page.evaluate(list => window.dispatchEvent(new CustomEvent("phx:posts:arrived", {detail: {list}})), list)

// The strip as the screen shows it.
const picture = (page: Page) => strip(page).screenshot()

const sideways = (page: Page) =>
  page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

async function open(page: Page) {
  await page.goto("/")
  await expect(page.locator("[data-phx-session].phx-connected:has(#pb-home-posts-rows)")).toBeAttached()
  await strip(page).scrollIntoViewIfNeeded()
}

test("the strip draws, a wave crosses it for each post, and it rests again", async ({page, isMobile}) => {
  let crashed = false
  page.on("crash", () => { crashed = true })

  for (const width of isMobile ? [390, 320] : [1280]) {
    await page.setViewportSize({width, height: 800})
    await open(page)
    await expect(strip(page)).toHaveAttribute("data-activity-pulse-ready", "true")
    await expect(strip(page).locator(".pb-pulse-still")).toBeHidden()
    const rest = await picture(page)

    // Another list's arrival is not this page's news.
    await arrive(page, "pb-site-posts")
    expect((await picture(page)).equals(rest)).toBe(true)

    // A wave runs for each arrival, starting again for the next, and the strip
    // is still once the last has crossed.
    await expect.poll(async () => {
      await arrive(page, "pb-home-posts")
      return (await picture(page)).equals(rest)
    }).toBe(false)
    await expect.poll(async () => (await picture(page)).equals(rest)).toBe(true)

    // The other theme repaints it in its own colours.
    await page.evaluate(() => {
      const root = document.documentElement
      const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches
      root.dataset.theme = dark ? "light" : "dark"
    })
    await expect.poll(async () => (await picture(page)).equals(rest)).toBe(false)

    expect(crashed).toBe(false)
    await expect(strip(page)).toHaveAttribute("data-activity-pulse-ready", "true")
    expect(await sideways(page)).toBe(0)
    const cdp = await page.context().newCDPSession(page)
    const {usedSize} = await cdp.send("Runtime.getHeapUsage")
    expect(usedSize).toBeLessThan(HEAP_CEILING)
  }
})

test.describe("with less motion", () => {
  test.use({reducedMotion: "reduce"})

  test("the strip keeps its still squares, and a post changes nothing", async ({page}) => {
    await open(page)
    await arrive(page, "pb-home-posts")
    await expect(strip(page).locator(".pb-pulse-still")).toBeVisible()
    await expect(strip(page).locator("canvas")).toBeHidden()
    await expect(strip(page)).not.toHaveAttribute("data-activity-pulse-ready")
    expect(await sideways(page)).toBe(0)
  })
})

test.describe("without WebGPU", () => {
  test("the strip says it will not draw and keeps its still squares", async ({page}) => {
    await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "gpu", {get: () => undefined}))
    await open(page)
    await expect(strip(page)).toHaveAttribute("data-activity-pulse-ready", "false")
    await expect(strip(page).locator(".pb-pulse-still")).toBeVisible()
    await expect(strip(page).locator("canvas")).toBeHidden()
    expect(await sideways(page)).toBe(0)
  })
})
