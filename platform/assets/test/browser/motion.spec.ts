import type {Locator, Page} from "@playwright/test"
import {connected, expect, inlineStyle, movesOf, movesWithin, press, test, toRest} from "./support/motion"
import {signedIn, watch} from "./support/test"

const MISSING_FIX = "/fixes/00000000-0000-0000-0000-000000000000"

const shakes = (moves: string[]) => moves.some(move => move.includes("translateX"))

// The home page's post form, opened by its link, filled in, and its button that
// asks for a preview.
async function askForPreview(page: Page, title = "Book a table for two on Friday") {
  await page.goto("/?ask=1")
  await page.getByRole("textbox", {name: "Issue", exact: true}).fill(title)
  await page.getByRole("textbox", {name: "The site"}).fill("https://example.com")
  return page.getByRole("button", {name: "Post to agent forum"})
}

const previewOf = (page: Page) => page.getByRole("region", {name: "Preview"})

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
    // The reason is about the title, so it is said under the title, where it
    // has stood since the title was left; the refusal is what shakes it.
    const reason = page.locator("#pb-fix-goal-errors")
    await expect(reason.locator("p")).toBeVisible()
    await expect.poll(async () => shakes(await movesOf(reason))).toBe(true)
    await toRest(reason)
    await expect(previewOf(page)).toHaveCount(0)
  })

  test("the buttons stay put while the address is looked at and answered", async ({page}) => {
    // The post button and the details toggle. On a phone both are under the
    // address; on a desktop the post button stands beside the question and the
    // toggle is under the address.
    const controls = [await askForPreview(page), page.getByRole("group").getByText("More", {exact: true})]
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
    // The page's answers come in order, the preview's held until the mouse has moved.
    await page.routeWebSocket(/\/live\/websocket/, socket => {
      const server = socket.connectToServer()
      socket.onMessage(message => server.send(message))
      let order = Promise.resolve()
      server.onMessage(message => {
        order = order.then(async () => {
          if (String(message).includes("pb:previewed")) await held
          socket.send(message)
        })
      })
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
    await page.goto("/account")
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

test.describe("the home page's lists", () => {
  const row = (page: Page) => page.locator("#pb-home-posts-rows > li").first()
  const tab = (page: Page) => page.locator(".pb-feed-tabs a:not([aria-current])").first()
  // The row's tint and the tab's underline, as the screen shows them.
  const looks = async (page: Page) => [
    await row(page).evaluate(el => getComputedStyle(el, "::before").opacity),
    await tab(page).evaluate(el => getComputedStyle(el, "::after").transform),
  ]

  test("a post row and a list tab answer a mouse, and stay as they are under a finger", async ({page, isMobile}) => {
    await page.goto("/")
    await page.locator("[data-phx-session].phx-connected:has(#pb-home-posts-rows)").waitFor({state: "attached"})
    const resting = ["0", "matrix(0, 0, 0, 1, 0, 0)"]
    expect(await looks(page)).toEqual(resting)

    for (const target of [row(page), tab(page)]) {
      await target.hover()
      expect(await target.evaluate(el => el.matches(":hover"))).toBe(true)
    }
    // A phone keeps what a finger touched hovered; nothing changes for it.
    if (isMobile) expect(await looks(page)).toEqual(resting)
    else {
      await row(page).hover()
      await expect.poll(async () => (await looks(page))[0]).toBe("0.5")
      await tab(page).hover()
      await expect.poll(async () => (await looks(page))[1]).toBe("none")
    }
  })
})

// A copy button dips as it is pressed, then says it copied, the old words
// fading as the new ones come in, and rests.
test("a copy button dips as it is pressed and crosses over to say it copied", async ({page, context, isMobile}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"])
  await page.goto("/")
  const copy = page.locator(".pb-connect-say .rg-copy").first()
  await copy.scrollIntoViewIfNeeded()
  await press(copy, isMobile)
  await expect(copy).toHaveAttribute("data-copy-state", "copied")
  await toRest(copy)
  expect((await movesOf(copy)).some(move => move.includes("scale"))).toBe(true)
  expect(await movesWithin(copy)).toContain("transition opacity")
})

// A post's follow bell tips from its top while a mouse holds it down and swings
// back as it is let go; held down from the keyboard it stays still.
test("a post's follow bell tips under a mouse and stays still under the keyboard", async ({page, isMobile}) => {
  test.skip(isMobile, "pressed with a mouse and with keys, on a desktop")
  await page.goto("/")
  await page.goto((await page.locator("a.pb-row-title").first().getAttribute("href"))!)
  // The bell is part of the thread's live part, which joins once.
  await page.locator("[data-phx-session].phx-connected:has(#pb-thread)").waitFor({state: "attached"})
  const bell = page.locator(".pb-follow-bell")
  const tilt = () => bell.locator(".rg-icon").evaluate(el => getComputedStyle(el).transform)
  const drawn = () => page.evaluate(() => new Promise(drawn => requestAnimationFrame(() => requestAnimationFrame(drawn))))

  // Slid off before it is let go, so the press follows nothing.
  await bell.hover()
  await page.mouse.down()
  await expect.poll(tilt).not.toBe("none")
  await page.mouse.move(0, 0)
  await page.mouse.up()
  await expect.poll(tilt).toBe("none")
  // A busy page can finish the swing back between two frames; the browser
  // tells of it in the next frame, so the moves are read once it is drawn.
  await drawn()

  const moves = await movesOf(bell.locator(".rg-icon"))
  await page.keyboard.press("Shift+Tab")
  await page.keyboard.press("Tab")
  await expect(bell).toBeFocused()
  await page.keyboard.down(" ")
  await drawn()
  expect(await movesOf(bell.locator(".rg-icon"))).toEqual(moves)
  expect(await tilt()).toBe("none")
})

test.describe("Ask a question", () => {
  // The form's panel, which folds open with the section.
  const form = (page: Page) => page.locator("#pb-ask > [data-panel='fold']")
  const summary = (page: Page) => page.locator("#pb-ask > summary")

  // Read once the next frame is drawn, when a fold started with the opening has
  // written its first step.
  async function opensStill(form: Locator) {
    await expect(form).toBeVisible()
    await form.page().evaluate(() => new Promise(drawn => requestAnimationFrame(() => requestAnimationFrame(drawn))))
    expect(await movesOf(form)).toEqual([])
    expect(await inlineStyle(form)).toBe("")
  }

  test("opened by hand, its form folds open and comes to rest", async ({page, isMobile}) => {
    await page.goto("/")
    await press(summary(page), isMobile)
    await expect(form(page)).toBeVisible()
    await toRest(form(page))
    expect((await movesOf(form(page))).some(move => move.includes("translateY"))).toBe(true)
  })

  test("opened from the keyboard, its form is simply there", async ({page, isMobile}) => {
    test.skip(isMobile, "a phone has no keyboard to open it with")
    await page.goto("/")
    await summary(page).focus()
    await page.keyboard.press("Enter")
    await opensStill(form(page))
  })

  test.describe("with less motion", () => {
    test.use({contextOptions: {reducedMotion: "reduce"}})

    test("its form is simply there", async ({page, isMobile}) => {
      await page.goto("/")
      await press(summary(page), isMobile)
      await opensStill(form(page))
    })
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
