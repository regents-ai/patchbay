import {expect, test as base, type Locator, type Page} from "@playwright/test"

// Every page in these checks records each move written onto any element, and
// reaches nothing but this machine's server. A page error fails the check it
// happened in.
export const test = base.extend<{errors: string[]}>({
  errors: [
    async ({page, baseURL}, use) => {
      const errors: string[] = []
      page.on("pageerror", error => errors.push(error.message))
      await page.route(url => !url.href.startsWith(baseURL!), route => route.abort())
      await page.addInitScript(recordMoves)
      await use(errors)
      expect(errors, "page errors").toEqual([])
    },
    {auto: true},
  ],
})

export {expect}

type Recorded = Element & {pbMoves?: string[]}

// Installed before any page script runs: each inline transform, translate or
// opacity written onto an element is kept on the element, in order.
function recordMoves() {
  const note = (el: Node) => {
    if (!(el instanceof HTMLElement || el instanceof SVGElement)) return
    const {transform, translate, opacity} = el.style
    const move = [
      transform && `transform ${transform}`,
      translate && translate !== "none" && `translate ${translate}`,
      opacity && `opacity ${opacity}`,
    ].filter(Boolean)
    if (move.length > 0) ((el as Recorded).pbMoves ??= []).push(move.join("; "))
  }

  new MutationObserver(changes => {
    for (const change of changes) {
      if (change.type === "attributes") note(change.target)
      change.addedNodes.forEach(note)
    }
  }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["style"]})
}

/** The moves written onto this element since the page loaded. */
export const movesOf = (locator: Locator) => locator.evaluate(el => (el as Recorded).pbMoves ?? [])

/** Forgets the moves recorded so far on every element of the page. */
export const forgetMoves = (page: Page) =>
  page.evaluate(() => document.querySelectorAll("*").forEach(el => delete (el as Recorded).pbMoves))

/** The element's inline style, "" when it has none. */
export const inlineStyle = (locator: Locator) => locator.evaluate(el => (el.getAttribute("style") ?? "").trim())

/** Waits until the element has no inline style: its motion has handed it back to the stylesheet. */
export const toRest = (locator: Locator) => expect.poll(() => inlineStyle(locator), {timeout: 5_000}).toBe("")

/** Whether the page scrolls sideways. */
export const sideways = (page: Page) =>
  page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)

/** Waits for the live page to connect. */
export const connected = (page: Page) => page.locator("[data-phx-main].phx-connected").waitFor()

/** Signs in as the payments lab's account, the one account this machine signs in without a wallet. */
export async function signIn(page: Page) {
  await page.goto("/dev/lab/payments")
  await page.getByRole("button", {name: "Sign in as the lab account"}).click()
  await expect(page.getByText("Signed in with A.")).toBeVisible()
}

/** Presses a control the way this project's reader does: a tap on the phone, a click with a mouse. */
export const press = (locator: Locator, isMobile: boolean) => (isMobile ? locator.tap() : locator.click())
