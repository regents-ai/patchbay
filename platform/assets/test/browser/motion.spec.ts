import {
  connected,
  expect,
  forgetMoves,
  inlineStyle,
  movesOf,
  press,
  signIn,
  sideways,
  test,
  toRest,
} from "./support/walk.ts"
import type {Page} from "@playwright/test"

const MISSING_FIX = "/fixes/00000000-0000-0000-0000-000000000000"

const shakes = (moves: string[]) => moves.some(move => move.includes("translateX"))
// While a list moves, its items are held where they stand by a translate; only
// one that changes while it plays has slid.
const places = (moves: string[]) =>
  new Set(moves.flatMap(move => move.split("; ").filter(part => !part.startsWith("opacity "))))
const slides = (moves: string[]) => places(moves).size > 1
// It fades when it is written see-through at some point on its way in.
const fades = (moves: string[]) =>
  moves.some(move => move.split("; ").some(part => part.startsWith("opacity ") && Number(part.slice(8)) < 1))

// The home page's form, filled in, and its button that asks for a preview.
async function askForPreview(page: Page) {
  await page.goto("/")
  await page.getByRole("textbox", {name: "Describe your WebMCP issue"}).fill("Book a table for two on Friday")
  await page.getByRole("textbox", {name: "The site"}).fill("https://example.com")
  return page.getByRole("button", {name: "Post to agent forum"})
}

const previewOf = (page: Page) => page.getByRole("region", {name: "Your post, exactly as everyone will see it"})

test.describe("the home page's preview", () => {
  test("asked for by hand, it settles in and ends at rest", async ({page, isMobile}) => {
    await press(await askForPreview(page), isMobile)
    const preview = previewOf(page)
    await expect(preview).toBeVisible()
    await toRest(preview)
    expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  })

  test("asked for from the keyboard, it stays still", async ({page, isMobile}) => {
    test.skip(isMobile, "a phone has no keyboard to ask with")
    const ask = await askForPreview(page)
    await ask.focus()
    await page.keyboard.press("Enter")
    const preview = previewOf(page)
    await expect(preview).toBeVisible()
    expect(await movesOf(preview)).toEqual([])
    expect(await inlineStyle(preview)).toBe("")
  })

  test("asked for from the keyboard, it stays still when the mouse moves during the wait", async ({page, isMobile}) => {
    test.skip(isMobile, "a phone has no keyboard to ask with")
    let answered!: () => void
    const held = new Promise<void>(resolve => (answered = resolve))
    await page.route("**/threads/preview", async route => {
      const response = await route.fetch()
      await held
      await route.fulfill({response})
    })
    const ask = await askForPreview(page)
    await ask.focus()
    await page.keyboard.press("Enter")
    for (const x of [200, 400, 600]) await page.mouse.move(x, 300)
    answered()
    const preview = previewOf(page)
    await expect(preview).toBeVisible()
    expect(await movesOf(preview)).toEqual([])
    expect(await inlineStyle(preview)).toBe("")
  })

  test.describe("with less motion", () => {
    test.use({contextOptions: {reducedMotion: "reduce"}})

    test("it stays still", async ({page, isMobile}) => {
      test.skip(isMobile, "the same page as at 1280; one run is enough")
      await (await askForPreview(page)).click()
      const preview = previewOf(page)
      await expect(preview).toBeVisible()
      expect(await movesOf(preview)).toEqual([])
      expect(await inlineStyle(preview)).toBe("")
    })
  })
})

test.describe("a note above the page", () => {
  const note = (page: Page) => page.getByRole("alert").filter({hasText: "There is no fix to show at that address."})

  test("shakes, then rests, after a full page load", async ({page}) => {
    await page.goto(MISSING_FIX)
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
  })

  test("shakes, then rests, after a live page sends the reader on", async ({page}) => {
    await page.goto("/offers")
    await connected(page)
    // A link a live page follows by sending the reader to another page.
    await page.evaluate(missing => {
      const link = document.createElement("a")
      link.textContent = "A fix that is not there"
      link.href = missing
      link.dataset.phxLink = "redirect"
      link.dataset.phxLinkState = "push"
      document.querySelector("[data-phx-main]")!.prepend(link)
    }, MISSING_FIX)
    await page.getByRole("link", {name: "A fix that is not there"}).click()
    await expect(page).toHaveURL("/")
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
  })
})

test.describe("the inbox's note about an old page link", () => {
  const note = (page: Page) => page.getByRole("alert").filter({hasText: "That inbox page link no longer works."})

  test("shakes, then rests, after a full page load", async ({page}) => {
    await signIn(page)
    await page.goto("/account/inbox?after=not-a-page")
    await connected(page)
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
    expect(await sideways(page)).toBe(false)
  })

  test("shakes, then rests, after a live change of page", async ({page}) => {
    await signIn(page)
    await page.goto("/account/inbox")
    await connected(page)
    // A link a live page follows without loading the page again.
    await page.evaluate(() => {
      const link = document.createElement("a")
      link.textContent = "An old inbox page"
      link.href = "/account/inbox?after=not-a-page"
      link.dataset.phxLink = "patch"
      link.dataset.phxLinkState = "push"
      document.querySelector("[data-phx-main]")!.prepend(link)
    })
    await page.getByRole("link", {name: "An old inbox page"}).click()
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
  })
})

test("a refused agent name shakes its reason, then rests", async ({page}) => {
  await signIn(page)
  await page.goto("/account/profile")
  await connected(page)
  await page.getByRole("textbox", {name: "The name your browser's agent posts under"}).fill("Not A Name!")
  await page.getByRole("button", {name: "Save", exact: true}).click()
  const reason = page.getByRole("alert").filter({hasText: "That name will not do."})
  await expect(reason).toBeVisible()
  await toRest(reason)
  expect(shakes(await movesOf(reason))).toBe(true)
  expect(await sideways(page)).toBe(false)
})

test("a saved Offer fades in, the row makes room, the count rolls, and every card ends with nothing written on it", async ({
  page,
}) => {
  await signIn(page)
  await page.goto("/offers/create")
  await connected(page)
  const saved = page.getByRole("region", {name: "Saved Offers"})
  const count = saved.getByText(/^\d+ saved/)
  const cards = saved.getByRole("list", {name: "Saved Offers, scroll horizontally"}).getByRole("listitem")

  const save = async (label: string) => {
    const before = await count.textContent()
    await page.getByRole("textbox", {name: "Private name"}).fill(label)
    await page.getByRole("textbox", {name: "Offer text"}).fill(`Try Patchbay to fix the tools on your site. ${label}`)
    await page.getByRole("button", {name: "Save Offer"}).click()
    await expect(cards.filter({hasText: label})).toBeVisible()
    await expect(count).not.toHaveText(before!)
  }

  const rested = async () => {
    for (const card of await cards.all()) {
      await toRest(card)
      expect(
        await card.evaluate(el => {
          const style = getComputedStyle(el)
          return [style.translate, style.transform, style.opacity]
        }),
      ).toEqual(["none", "none", "1"])
    }
    // The count is the plain figure again, not the pieces it rolled in.
    await expect(count).toHaveText(/^\d+ saved/)
    expect(await count.evaluate(el => el.firstElementChild?.childElementCount)).toBe(0)
  }

  const first = `First ${Date.now().toString(36)}`
  await save(first)
  await rested()
  await forgetMoves(page)

  const second = `Second ${Date.now().toString(36)}`
  await save(second)
  await rested()
  const arrived = await movesOf(cards.filter({hasText: second}))
  expect(fades(arrived)).toBe(true)
  expect(slides(arrived)).toBe(false)
  expect(slides(await movesOf(cards.filter({hasText: first})))).toBe(true)
  expect(await sideways(page)).toBe(false)
})

test("Claude's picture tilts under a mouse and stays put after a tap", async ({page, isMobile}) => {
  await page.goto("/claude")
  // The crowd is decoration, hidden from assistive technology; its first figure.
  const hero = page.getByRole("region", {name: "Get Claude Code through any website."})
  const figure = hero.locator("svg").first()
  if (isMobile) {
    await figure.tap({force: true})
    await page.waitForTimeout(400)
    expect(await figure.evaluate(el => getComputedStyle(el).transform)).toBe("none")
  } else {
    expect(await figure.evaluate(el => getComputedStyle(el).transitionDuration)).toBe("0.28s")
    await figure.hover({force: true})
    await expect.poll(() => figure.evaluate(el => getComputedStyle(el).transform)).not.toBe("none")
  }
})
