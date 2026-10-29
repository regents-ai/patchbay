import type {Locator, Page} from "@playwright/test"
import {
  connected,
  expect,
  forgetMoves,
  inlineStyle,
  movesInside,
  movesOf,
  movesWithin,
  press,
  test,
  toRest,
  watchInside,
} from "./support/motion"
import {signInFile, signedIn, watch} from "./support/test"

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

// The home page's post form, opened by its link, filled in, and its button that
// asks for a preview.
async function askForPreview(page: Page, title = "Book a table for two on Friday") {
  await page.goto("/?ask=1")
  await page.getByRole("textbox", {name: "Issue", exact: true}).fill(title)
  await page.getByRole("textbox", {name: "The site"}).fill("https://example.com")
  return page.getByRole("button", {name: "Post to agent forum"})
}

const previewOf = (page: Page) => page.getByRole("region", {name: "Your post, exactly as everyone will see it"})

// Read once the next frame is drawn, when a motion started with the preview has
// written its first step: nothing moved on it or inside it, from a script or the
// stylesheet, and nothing is moving.
async function staysStill(preview: Locator) {
  await preview.page().evaluate(() => new Promise(drawn => requestAnimationFrame(drawn)))
  expect(await movesWithin(preview)).toEqual([])
  expect(await preview.evaluate(el => el.getAnimations({subtree: true}).length)).toBe(0)
  expect(await inlineStyle(preview)).toBe("")
}

test.describe("the home page's preview", () => {
  test("asked for by hand, it settles in and ends at rest", async ({page, isMobile}) => {
    await press(await askForPreview(page), isMobile)
    const preview = previewOf(page)
    await expect(preview).toBeVisible()
    await toRest(preview)
    expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  })

  test("with a box asking to check something private, it settles in whole, and the box does not shake", async ({
    page,
    isMobile,
  }) => {
    await press(await askForPreview(page, "Book a table for two, then mail me at diner@example.com"), isMobile)
    const preview = previewOf(page)
    const check = preview.getByRole("alert").filter({hasText: "Check before posting."})
    await expect(check).toBeVisible()
    await toRest(preview)
    expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
    expect(shakes(await movesWithin(check))).toBe(false)
  })

  test("a refused preview shakes its reason, then rests", async ({page, isMobile}) => {
    await press(await askForPreview(page, `Book a table for two on Friday ${"and again ".repeat(15)}`), isMobile)
    const reason = page.getByRole("alert").filter({hasText: "A forum post's title is what you are trying to do"})
    await expect(reason).toBeVisible()
    await toRest(reason)
    expect(shakes(await movesOf(reason))).toBe(true)
    await expect(previewOf(page)).toHaveCount(0)
  })

  test("the buttons stay put while the address is looked at and answered", async ({page}) => {
    // The post button and the details toggle. On a phone both are under the
    // address; on a desktop the post button stands beside the question and the
    // toggle is under the address.
    const controls = [await askForPreview(page), page.getByRole("group").getByText("Details help find a solution")]
    const places = () => Promise.all(controls.map(control => control.boundingBox()))
    const before = await places()
    // Leaving the field asks at once, as a tap on the button does; what is
    // found is said under it, as the field's description.
    const site = page.getByRole("textbox", {name: "The site"})
    await site.blur()
    await expect(site).toHaveAccessibleDescription("Looking for WebMCP tools at this address…")
    expect(await places()).toEqual(before)
    await expect(site).toHaveAccessibleDescription("That address does not lead to any site.")
    expect(await places()).toEqual(before)
  })

  test("asked for from the keyboard, it stays still", async ({page, isMobile}) => {
    test.skip(isMobile, "a phone has no keyboard to ask with")
    const ask = await askForPreview(page)
    await ask.focus()
    await page.keyboard.press("Enter")
    const preview = previewOf(page)
    await expect(preview).toBeVisible()
    await staysStill(preview)
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
    await staysStill(preview)
  })

  test.describe("with less motion", () => {
    test.use({contextOptions: {reducedMotion: "reduce"}})

    test("it stays still", async ({page, isMobile}) => {
      test.skip(isMobile, "the same page as at 1280; one run is enough")
      await (await askForPreview(page)).click()
      const preview = previewOf(page)
      await expect(preview).toBeVisible()
      await staysStill(preview)
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
    await page.getByRole("main").evaluate((main, missing) => {
      const link = document.createElement("a")
      link.textContent = "A fix that is not there"
      link.href = missing
      link.dataset.phxLink = "redirect"
      link.dataset.phxLinkState = "push"
      main.prepend(link)
    }, MISSING_FIX)
    await page.getByRole("link", {name: "A fix that is not there"}).click()
    await expect(page).toHaveURL("/")
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
  })
})

test.describe("the inbox's note about an old page link", () => {
  test.use(signedIn)
  const note = (page: Page) => page.getByRole("alert").filter({hasText: "That inbox page link no longer works."})

  test("shakes, then rests, after a full page load", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/inbox?after=not-a-page")
    await connected(page)
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
    await problems.expect()
  })

  test("shakes, then rests, after a live change of page", async ({page}) => {
    await page.goto("/account/inbox")
    await connected(page)
    // A link a live page follows without loading the page again.
    await page.getByRole("main").evaluate(main => {
      const link = document.createElement("a")
      link.textContent = "An old inbox page"
      link.href = "/account/inbox?after=not-a-page"
      link.dataset.phxLink = "patch"
      link.dataset.phxLinkState = "push"
      main.prepend(link)
    })
    await page.getByRole("link", {name: "An old inbox page"}).click()
    await expect(note(page)).toBeVisible()
    await toRest(note(page))
    expect(shakes(await movesOf(note(page)))).toBe(true)
  })
})

test.describe("the agent name form", () => {
  test.use(signedIn)

  test("a refused name shakes its reason, then rests", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/profile")
    await connected(page)
    await page.getByRole("textbox", {name: "Agent name"}).fill("Not A Name!")
    await page.getByRole("button", {name: "Save", exact: true}).click()
    const reason = page.getByRole("alert").filter({hasText: "That name doesn't fit the rules."})
    await expect(reason).toBeVisible()
    await toRest(reason)
    expect(shakes(await movesOf(reason))).toBe(true)
    await problems.expect()
  })
})

test.describe("saving an Offer", () => {
  // Each width saves as its own person: an account saves five wordings a day,
  // and the widths run at once (support/sign_in.exs).
  test.use({
    storageState: async ({}, use, info) =>
      use(signInFile(`offers-${info.project.name.replace(/\W+/g, "-")}`)),
  })

  test("a refused save shakes its reason, then rests", async ({page}) => {
    const problems = watch(page)
    await page.goto("/offers/create")
    await connected(page)
    await page.getByRole("textbox", {name: "Private name"}).fill("Two lines")
    await page.getByRole("textbox", {name: "Offer text"}).fill("Try Patchbay.\nOn two lines.")
    await page.getByRole("button", {name: "Save Offer"}).click()
    const reason = page.getByRole("alert").filter({hasText: "The wording must be a single line."})
    await expect(reason).toBeVisible()
    await toRest(reason)
    expect(shakes(await movesOf(reason))).toBe(true)
    await problems.expect()
  })

  test("a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it", async ({
    page,
  }) => {
    const problems = watch(page)
    await page.goto("/offers/create")
    await connected(page)
    const saved = page.getByRole("region", {name: "Saved Offers"})
    const count = saved.getByText(/^\d+ saved/)
    const row = saved.getByRole("list", {name: "Saved Offers, scroll horizontally"})
    const cards = row.getByRole("listitem")

    const save = async (label: string) => {
      const before = await count.textContent()
      await page.getByRole("textbox", {name: "Private name"}).fill(label)
      await page.getByRole("textbox", {name: "Offer text"}).fill(`Try Patchbay to fix the tools on your site. ${label}`)
      await page.getByRole("button", {name: "Save Offer"}).click()
      await expect(cards.filter({hasText: label})).toBeVisible()
      await expect(count).not.toHaveText(before!)
    }

    const rested = async () => {
      await toRest(row)
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
    await watchInside(count)
    await save(second)
    await rested()
    const arrived = await movesOf(cards.filter({hasText: second}))
    expect(fades(arrived)).toBe(true)
    // The new card comes first, in the row's view, whole, not scrolled past.
    await expect(cards.first()).toContainText(second)
    const [seen, card] = [await row.boundingBox(), await cards.filter({hasText: second}).boundingBox()]
    expect(card!.x).toBeGreaterThanOrEqual(seen!.x)
    expect(card!.x + card!.width).toBeLessThanOrEqual(seen!.x + seen!.width)
    expect((await movesInside(count)).some(move => move.includes("translateY"))).toBe(true)
    expect(slides(arrived)).toBe(false)
    // Nor does the stylesheet move it on its way in.
    expect(arrived.filter(move => /^(animation|transition) /.test(move))).toEqual([])
    expect(slides(await movesOf(cards.filter({hasText: first})))).toBe(true)
    await problems.expect()
  })
})

test("Claude's picture tilts under a mouse and stays put after a tap", async ({page, isMobile}) => {
  await page.goto("/claude")
  // The crowd is decoration, hidden from assistive technology; its first figure.
  const hero = page.getByRole("region", {name: "Claude Code", exact: true})
  const figure = hero.getByRole("img", {includeHidden: true}).first()
  if (isMobile) {
    await figure.tap({force: true})
    // The tap leaves the picture hovered, as a phone does; asking for its
    // animations brings its style up to date, so a tilt it set off is there.
    expect(await figure.evaluate(el => el.matches(":hover"))).toBe(true)
    expect(await figure.evaluate(el => [el.getAnimations().length, getComputedStyle(el).transform])).toEqual([0, "none"])
  } else {
    expect(await figure.evaluate(el => getComputedStyle(el).transitionDuration)).toBe("0.28s")
    await figure.hover({force: true})
    await expect.poll(() => figure.evaluate(el => getComputedStyle(el).transform)).not.toBe("none")
  }
})
