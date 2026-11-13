import type {Browser, Locator, Page} from "@playwright/test"
import {expect, inlineStyle, movesOf, test, toRest} from "./support/motion"
import {keepOnThisMachine, signInFile, signedIn, watch} from "./support/test"

// What others publish reaches a page that is open, without a reload: a new
// post at the top of the home page's list, a reply at the end of a post's
// replies. It settles in where it lands and nothing else moves but by the room
// it takes; a reader scrolled down keeps what they were reading where it was,
// and what they were typing stays. The posts come from a second browser signed
// in as the walk's person, through the post form and the reply form. At 1280
// and 390; the 320 phone draws the same lists.

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name === "small phone", "checked at 1280 and 390")
})

// The second browser, which keeps to this machine as the first does.
async function openPoster(browser: Browser, baseURL: string) {
  const context = await browser.newContext({baseURL, storageState: signInFile("person")})
  const outside = await keepOnThisMachine(context, baseURL)
  const page = await context.newPage()
  // The site's tool check is answered here, as in draft.spec.ts: it is not what
  // these walks are about.
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({status: "none", said: "", tools: [], directory: false}),
    }))

  return {
    // Publishes a question from the post form, with what was tried, and gives
    // its page's address. It is asked about a site no other walk opens, so the
    // site pages they check stay as the walk drew them.
    async ask(title: string) {
      await page.goto("/hermes")
      await page.locator("#pb-fix-goal").fill(title)
      await page.locator("#pb-fix-site").fill("example.com")
      const details = page.locator("#pb-hero-details")
      if (!(await details.evaluate(el => (el as HTMLDetailsElement).open))) await details.locator("summary").click()
      await page.locator("#pb-hero-body").fill("Tried it twice in a fresh session, and once more after signing in again.")
      await page.locator("[data-pb-preview]").filter({visible: true}).first().click()
      const publish = page.locator("[data-pb-post]")
      await expect(publish).toBeVisible()
      await Promise.all([page.waitForURL(/\/posts\//), publish.click()])
      return new URL(page.url()).pathname
    },

    async reply(path: string, words: string) {
      await page.goto(path)
      await page.locator("#pb-reply-body").fill(words)
      await Promise.all([page.waitForEvent("load"), page.getByRole("button", {name: "Post reply"}).click()])
    },

    async close() {
      await context.close()
      expect(outside, "requests the second browser made outside this machine").toEqual([])
    },
  }
}

const unique = (words: string) => `${words} ${Math.random().toString(36).slice(2, 8)}`

// A mark on the page that a reload would take away.
const markPage = (page: Page) => page.evaluate(() => Object.assign(window, {pbSamePage: true}))
const samePage = (page: Page) => page.evaluate(() => (window as Window & {pbSamePage?: boolean}).pbSamePage === true)

// The page's live part around `inside` has joined. It draws no box of its own,
// so it is found in the page rather than seen.
const joined = (page: Page, inside: string) =>
  page.locator(`[data-phx-session].phx-connected:has(${inside})`).waitFor({state: "attached"})

async function openHome(page: Page) {
  await page.goto("/")
  await joined(page, "#pb-home-posts-rows")
  await markPage(page)
  return page.locator("#pb-home-posts-rows")
}

type Resting = {list: number; rows: {id: string; top: number; kept: boolean}[]}

// Where the list and each of its rows sit on the page, read in one frame once
// none of them is moving. A row marked kept is the same element as before.
async function resting(list: Locator): Promise<Resting> {
  const ol = await list.elementHandle()
  const found = await list.page().waitForFunction(ol => {
    const rows = [...ol!.children] as (HTMLElement & {pbKept?: true})[]
    if (rows.some(row => row.getAttribute("style") || row.getAnimations().length > 0)) return false
    return {
      list: ol!.getBoundingClientRect().top + scrollY,
      rows: rows.map(row => ({id: row.id, top: row.getBoundingClientRect().top + scrollY, kept: row.pbKept === true})),
    }
  }, ol)
  return (await found.jsonValue()) as Resting
}

// The row arrives, settles in, and comes to rest.
async function arrives(row: Locator) {
  await expect(row).toBeAttached()
  await expect.poll(() => movesOf(row)).not.toEqual([])
  await toRest(row)
}

// Within a pixel: a scrolled page stops on whole pixels, rows need not.
const near = (now: number, was: number) => expect(Math.abs(now - was)).toBeLessThanOrEqual(1)

// Each move written on a figure's digits while it rolls. The digits are
// joined back into the figure once the roll ends, so the moves are kept on
// the page rather than on them.
const watchRoll = (figure: Locator) =>
  figure.evaluate(el => {
    const moves: string[] = []
    Object.assign(window, {pbRoll: moves})
    new MutationObserver(changes => {
      for (const change of changes) {
        const moved = (change.target as HTMLElement).style.transform
        if (moved) moves.push(moved)
      }
    }).observe(el, {subtree: true, attributes: true, attributeFilter: ["style"]})
  })
const rolled = (page: Page) => page.evaluate(() => (window as Window & {pbRoll?: string[]}).pbRoll ?? [])

test("a post published elsewhere arrives at the top of the home page's list, moving the rest down by its own room", async ({
  page,
  browser,
  baseURL,
}) => {
  const problems = watch(page)
  const list = await openHome(page)
  await list.locator(":scope > li").first().evaluate(row => Object.assign(row, {pbKept: true}))
  const before = await resting(list)
  const first = before.rows[0]

  const poster = await openPoster(browser, baseURL!)
  const title = unique("Cart total doubles at checkout")
  await poster.ask(title)

  const row = list.locator(":scope > li", {hasText: title})
  await arrives(row)
  const after = await resting(list)
  const kept = after.rows.findIndex(row => row.id === first.id)
  const arrived = after.rows.slice(0, kept).map(row => row.id)

  expect(await samePage(page)).toBe(true)
  expect(arrived).toContain(await row.getAttribute("id"))
  // The row that was first is the same row, now under what arrived: what
  // arrived begins where it began, and nothing above the list moved.
  expect(after.rows[kept].kept).toBe(true)
  near(after.rows[0].top, first.top)
  near(after.list, before.list)
  await problems.expect()
  await poster.close()
})

test("a reader scrolled down the home page keeps the post they were reading where it was", async ({
  page,
  browser,
  baseURL,
}) => {
  const problems = watch(page)
  const list = await openHome(page)
  const id = await list.locator(":scope > li").first().getAttribute("id")
  const reading = page.locator(`#${id}`)
  await reading.evaluate(row => row.scrollIntoView({block: "start"}))
  await resting(list)
  expect(await page.evaluate(() => scrollY)).toBeGreaterThan(0)
  const where = await reading.evaluate(row => row.getBoundingClientRect().top)

  const poster = await openPoster(browser, baseURL!)
  const title = unique("Search box forgets the last query")
  await poster.ask(title)

  await arrives(list.locator(":scope > li", {hasText: title}))
  await resting(list)
  expect(await samePage(page)).toBe(true)
  near(await reading.evaluate(row => row.getBoundingClientRect().top), where)
  await problems.expect()
  await poster.close()
})

test.describe("with reduced motion", () => {
  test.use({contextOptions: {reducedMotion: "reduce"}})

  test("a new post is simply there", async ({page, browser, baseURL}) => {
    const list = await openHome(page)
    const poster = await openPoster(browser, baseURL!)
    const title = unique("Map stays blank after login")
    await poster.ask(title)

    const row = list.locator(":scope > li", {hasText: title})
    await expect(row).toBeVisible()
    await page.evaluate(() => new Promise(drawn => requestAnimationFrame(() => requestAnimationFrame(drawn))))
    expect(await movesOf(row)).toEqual([])
    expect(await inlineStyle(row)).toBe("")
    await poster.close()
  })
})

test.describe("a post's page", () => {
  test.use(signedIn)

  test("a reply published elsewhere arrives at the end, and the reply being typed stays, where it was", async ({
    page,
    browser,
    baseURL,
  }) => {
    const poster = await openPoster(browser, baseURL!)
    const path = await poster.ask(unique("Coupon field ignores every code"))

    const problems = watch(page)
    await page.goto(path)
    await joined(page, "#patchbay-replies")
    await markPage(page)
    const title = page.locator(".rg-discussion__title")
    const titleTop = await title.evaluate(el => el.getBoundingClientRect().top + scrollY)
    const typing = page.locator("#pb-reply-body")
    await typing.fill("Half typed: I cleared the cart and")
    await typing.evaluate(el => el.scrollIntoView({block: "center"}))
    expect(await page.evaluate(() => scrollY)).toBeGreaterThan(0)
    const where = await typing.evaluate(el => el.getBoundingClientRect().top)
    const count = page.locator("#patchbay-replies-title > span")
    await watchRoll(count)

    const words = unique("Applying the code before the address works.")
    await poster.reply(path, words)

    const reply = page.locator(".rg-discussion__replies > li", {hasText: words})
    await arrives(reply)
    await expect(page.locator(".rg-discussion__replies > li")).toHaveCount(1)
    await expect(count).toHaveText("1")
    await expect.poll(() => rolled(page)).not.toEqual([])

    expect(await samePage(page)).toBe(true)
    await expect(typing).toHaveValue("Half typed: I cleared the cart and")
    await expect(typing).toBeFocused()
    near(await typing.evaluate(el => el.getBoundingClientRect().top), where)
    near(await title.evaluate(el => el.getBoundingClientRect().top + scrollY), titleTop)
    await problems.expect()
    await poster.close()
  })
})
