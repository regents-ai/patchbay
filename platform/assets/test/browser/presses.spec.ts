import {readFileSync} from "node:fs"
import {type Locator, type Page} from "@playwright/test"
import {connected, press} from "./support/motion"
import {expect, signInFile, signedIn, test, watch} from "./support/test"

// A reader's own presses change the page where it stands: the hearts, the
// follow bell, "This answered it", "Worked", "Stop following" and a new agent
// name. The page never loads again, so it keeps the reader's place, a marker
// left on the window and a reply half typed. Each width presses its own question,
// incident and followed board (report.exs), so the widths never meet.

type Places = {question: string; incident: string; followed: string}
const places = (): Places =>
  JSON.parse(readFileSync(signInFile("presses"), "utf8"))[test.info().project.name.replace(/\W+/g, "-")]

// Leaves a marker on the window; a page loaded again would not have it.
async function stays(page: Page) {
  await page.evaluate(() => Object.assign(window, {pbStayed: true}))
  return async () =>
    expect(await page.evaluate(() => (window as unknown as {pbStayed?: boolean}).pbStayed), "the same page").toBe(true)
}

// Presses a control in the middle of the screen and waits for what it changes. A
// control still there after the press is still on screen: the reader is where they
// were. (On a phone a reply's heart moves down a line once "Liked by" joins it, so
// one pressed at the screen's very edge would leave it.)
async function pressInPlace(control: Locator, how: "pointer" | "keys", isMobile: boolean, done: () => Promise<void>) {
  await control.evaluate(part => part.scrollIntoView({block: "center", behavior: "instant"}))
  if (how === "keys") {
    await control.focus()
    await control.page().keyboard.press("Enter")
  } else await press(control, isMobile)
  await done()
  if ((await control.count()) > 0) await expect(control).toBeInViewport()
}

// The post page's thread is its own live part, inside the page, found there
// rather than seen.
const threadConnected = (page: Page) =>
  page.locator("[data-phx-session].phx-connected:has(#pb-thread)").waitFor({state: "attached"})

const heart = (post: Locator) => post.locator(".rg-discussion__heart")
const reply = (page: Page) => page.locator(".rg-discussion__post:not(#pb-post)").filter({hasText: "Clearing the site's cookies"})

async function likesTwice(post: Locator, isMobile: boolean) {
  await pressInPlace(heart(post), "pointer", isMobile, async () => {
    await expect(heart(post)).toHaveAttribute("aria-pressed", "true")
    await expect(heart(post)).toContainText("Like, 1 like")
    await expect(post.locator(".rg-discussion__liked-by")).toBeVisible()
  })
  await pressInPlace(heart(post), "keys", isMobile, async () => {
    await expect(heart(post)).toHaveAttribute("aria-pressed", "false")
    await expect(heart(post)).toContainText("Like, 0 likes")
    await expect(post.locator(".rg-discussion__liked-by")).toHaveCount(0)
  })
}

test.describe("signed in", () => {
  test.use(signedIn)

  test("hearts, the bell and the asker's mark change the question where it stands", async ({page, isMobile}) => {
    const problems = watch(page)
    await page.goto(places().question)
    await threadConnected(page)
    const stayed = await stays(page)
    await page.locator("#pb-reply-body").fill("Half a reply")

    await likesTwice(page.locator("#pb-post"), isMobile)
    await likesTwice(reply(page), isMobile)

    const bell = page.locator(".pb-follow-bell")
    await pressInPlace(bell, "pointer", isMobile, () => expect(bell).toHaveAttribute("aria-pressed", "true"))
    await pressInPlace(bell, "keys", isMobile, () => expect(bell).toHaveAttribute("aria-pressed", "false"))

    // The answer it names goes up above the question, so the page under the
    // reader may move; it does not load again.
    const mark = reply(page).getByRole("button", {name: "This answered it"})
    await press(mark, isMobile)
    await expect(page.locator("#pb-fix")).toBeVisible()
    await expect(mark).toHaveCount(0)

    await expect(page.locator("#pb-reply-body")).toHaveValue("Half a reply")
    await stayed()
    await problems.expect()
  })

  test("a heart and Worked change an incident's discussion where it stands", async ({page, isMobile}) => {
    const problems = watch(page)
    await page.goto(places().incident)
    await threadConnected(page)
    const stayed = await stays(page)
    await page.locator("#pb-reply-body").fill("Half a reply")

    await likesTwice(page.locator("#pb-post"), isMobile)

    const worked = reply(page).locator("button[phx-click=worked]")
    await pressInPlace(worked, "pointer", isMobile, async () => {
      await expect(worked).toHaveAttribute("aria-pressed", "true")
      await expect(reply(page)).toContainText("Worked for 1 other")
    })
    await pressInPlace(worked, "keys", isMobile, async () => {
      await expect(worked).toHaveAttribute("aria-pressed", "false")
      await expect(reply(page)).not.toContainText("Worked for")
    })

    await expect(page.locator("#pb-reply-body")).toHaveValue("Half a reply")
    await stayed()
    await problems.expect()
  })

  test("Stop following takes the board off the inbox where it stands", async ({page, isMobile}) => {
    const problems = watch(page)
    await page.goto("/account/inbox")
    await connected(page)
    const stayed = await stays(page)
    const row = page.locator("#account-inbox li").filter({has: page.locator(`a[href="/${places().followed}"]`)})

    await pressInPlace(row.getByRole("button", {name: "Stop following"}), "pointer", isMobile, () =>
      expect(row).toHaveCount(0),
    )

    await stayed()
    await problems.expect()
  })
})

// Signed out, with less motion: a heart says to sign in beside it, and the bell
// follows for this browser.
test.describe("signed out, with less motion", () => {
  test.use({contextOptions: {reducedMotion: "reduce"}})

  test("a heart says why where it was pressed, and the bell follows for the browser", async ({page, isMobile}) => {
    const problems = watch(page)
    await page.goto(places().question)
    await threadConnected(page)
    const stayed = await stays(page)

    const post = page.locator("#pb-post")
    await pressInPlace(heart(post), "pointer", isMobile, () =>
      expect(page.locator("#pb-post-refused")).toHaveText("Sign in at the top of the page to like posts."),
    )
    await expect(heart(post)).toHaveAttribute("aria-pressed", "false")

    const bell = page.locator(".pb-follow-bell")
    await pressInPlace(bell, "keys", isMobile, () => expect(bell).toHaveAttribute("aria-pressed", "true"))
    await pressInPlace(bell, "pointer", isMobile, () => expect(bell).toHaveAttribute("aria-pressed", "false"))
    await expect(page.locator("#pb-post-refused")).toHaveCount(0)

    await stayed()
    await problems.expect()
  })
})
