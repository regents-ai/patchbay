import {readFileSync} from "node:fs"
import type {BrowserContext, Locator, Page} from "@playwright/test"
import {expect, signInFile, test, watch} from "./support/test"

// What a person types in the ask form comes back after they sign in, by the
// header's Sign in or by Publish, on home, an agent page and a site page's post
// window, and the form it comes back to is in view. Found on 29 Oct (the PB-13
// review): the form's own Sign in was gone, the post window covered the header's
// and opened Privy under itself, home put the draft back inside a closed "Ask a
// question", and a draft typed on /hermes turned up in another page's form.

// A Privy sign-in that goes through: the bridge says signed in, the session
// address answers and the browser now carries the walk person's cookie, and the
// page reloads as it does after a real sign-in.
const signedInBridge = `
export async function profile() { return {ok: false, status: null, error: {code: "authentication_required", outcome_unknown: false}} }
export async function signIn() { return {ok: true, access: "access", identity: "identity"} }
export async function signOut() {}
export async function activeWallet() { return {ok: false, reason: "signed_out"} }
export async function activeAddress() { return null }
export async function addFundsByCard() { return {ok: false, reason: "signed_out"} }
`

async function signInGoesThrough(page: Page, context: BrowserContext) {
  await page.route(/\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/, route =>
    route.fulfill({contentType: "text/javascript", body: signedInBridge}))
  await page.route("**/auth/privy/session", async route => {
    const saved = JSON.parse(readFileSync(signInFile("person"), "utf8"))
    await context.addCookies(saved.cookies)
    await route.fulfill({status: 200, contentType: "application/json", body: "{}"})
  })
}

const DRAFT = {
  goal: "Booking tool refuses my date",
  site: "keyfleet.ai",
  details: "I tried book_table with 2025-11-01 and got invalid_date",
  tags: "booking",
}

async function fillDraft(form: Locator) {
  await form.locator("#pb-fix-goal").fill(DRAFT.goal)
  await form.locator("#pb-fix-site").fill(DRAFT.site)
  const details = form.locator("#pb-hero-details")
  if (!(await details.evaluate(element => (element as HTMLDetailsElement).open))) await details.locator("summary").click()
  await form.locator("#pb-hero-body").fill(DRAFT.details)
  await form.locator("#pb-hero-tags").fill(DRAFT.tags)
}

// Signed in now, every field back, and the form in view without a press.
async function expectDraftBack(page: Page) {
  const form = page.locator("#pb-hero-form")
  await expect(form).toHaveAttribute("data-pb-signed-in", "true")
  await expect(form.locator("#pb-fix-goal")).toBeVisible()
  await expect(form.locator("#pb-fix-goal")).toHaveValue(DRAFT.goal)
  await expect(form.locator("#pb-fix-site")).toHaveValue(DRAFT.site)
  await expect(form.locator("#pb-hero-body")).toHaveValue(DRAFT.details)
  await expect(form.locator("#pb-hero-tags")).toHaveValue(DRAFT.tags)
}

async function publish(page: Page, form: Locator) {
  await form.locator("[data-pb-preview]").filter({visible: true}).first().click()
  const button = form.locator("[data-pb-post]")
  await expect(button).toBeVisible()
  await Promise.all([page.waitForEvent("load"), button.click()])
}

// At 1280 and 390; the 320 phone takes the same paths as the 390 one.
test.beforeEach(({}, info) => test.skip(info.project.name === "small phone", "checked at 1280 and 390"))

for (const path of ["/", "/hermes"]) {
  test(`a draft on ${path} comes back after the header's Sign in`, async ({page, context}) => {
    await signInGoesThrough(page, context)
    const problems = watch(page)
    await page.goto(path)
    if (path === "/") await page.locator("#pb-ask > summary").click()
    await fillDraft(page.locator("#pb-hero-form"))
    const signIn = page.locator("[data-account-target='sign-in']").filter({visible: true})
    await expect(signIn).toHaveCount(1)
    await Promise.all([page.waitForEvent("load"), signIn.click()])
    await expectDraftBack(page)
    await problems.expect()
  })

  test(`a draft on ${path} comes back after Publish asks for a sign-in`, async ({page, context}) => {
    await signInGoesThrough(page, context)
    const problems = watch(page)
    await page.goto(path)
    if (path === "/") await page.locator("#pb-ask > summary").click()
    await fillDraft(page.locator("#pb-hero-form"))
    await publish(page, page.locator("#pb-hero-form"))
    await expectDraftBack(page)
    await problems.expect()
  })
}

test.describe("a site page's post window", () => {
  const openWindow = async (page: Page) => {
    await page.goto("/keyfleet.ai")
    await page.locator("a[href='#pb-site-post']").first().click()
    const postWindow = page.locator("#pb-site-post")
    await expect(postWindow).toBeVisible()
    return postWindow
  }

  test("Publish closes the window for the sign-in, and the window opens again with the draft", async ({page, context}) => {
    await signInGoesThrough(page, context)
    const problems = watch(page)
    const postWindow = await openWindow(page)
    await fillDraft(postWindow.locator("#pb-hero-form"))
    await publish(page, postWindow.locator("#pb-hero-form"))
    await expect(page.locator("#pb-site-post")).toBeVisible()
    await expectDraftBack(page)
    await problems.expect()
  })

  test("the window's own Sign in is the one in view, and the draft comes back", async ({page, context}) => {
    await signInGoesThrough(page, context)
    const problems = watch(page)
    const postWindow = await openWindow(page)
    await fillDraft(postWindow.locator("#pb-hero-form"))
    const signIn = page.locator("[data-account-target='sign-in']").filter({visible: true})
    await expect(signIn).toHaveCount(2)
    // The window covers the header's, so the window's is the one a press reaches.
    const reached = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("[data-account-target='sign-in']")]
        .filter(button => {
          const box = button.getBoundingClientRect()
          if (box.width === 0) return false
          const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)
          return hit !== null && button.contains(hit)
        })
        .map(button => button.closest("#pb-site-post") !== null))
    expect(reached).toEqual([true])
    await Promise.all([page.waitForEvent("load"), postWindow.locator("[data-account-target='sign-in']").click()])
    await expect(page.locator("#pb-site-post")).toBeVisible()
    await expectDraftBack(page)
    await problems.expect()
  })

  test("closed, then the header's Sign in, the window opens again with the draft", async ({page, context}) => {
    await signInGoesThrough(page, context)
    const problems = watch(page)
    const postWindow = await openWindow(page)
    await fillDraft(postWindow.locator("#pb-hero-form"))
    await page.keyboard.press("Escape")
    await expect(postWindow).toBeHidden()
    const signIn = page.locator("[data-account-target='sign-in']").filter({visible: true})
    await expect(signIn).toHaveCount(1)
    await Promise.all([page.waitForEvent("load"), signIn.click()])
    await expect(page.locator("#pb-site-post")).toBeVisible()
    await expectDraftBack(page)
    await problems.expect()
  })
})

test("a draft kept on /hermes stays on /hermes", async ({page}) => {
  const problems = watch(page)
  await page.goto("/hermes")
  await page.locator("#pb-fix-goal").fill("Typed on Hermes's page")
  // The walk's sign-in is turned down, so the draft is kept and nothing reloads.
  await page.locator("[data-account-target='sign-in']").filter({visible: true}).click()
  await page.goto("/claude")
  await expect(page.locator("#pb-fix-goal")).toHaveValue("")
  await page.goto("/hermes")
  await expect(page.locator("#pb-fix-goal")).toHaveValue("Typed on Hermes's page")
  await problems.expect()
})
