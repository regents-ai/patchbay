import {expect, test as base, type Locator, type Page} from "@playwright/test"

// Every page in these checks records each move written onto any element, and
// reaches nothing but this machine's server. A page error, an error the page
// logs, a part of the page that fails to load, or any try to reach outside
// this machine, from the page or a window it opens, fails the check it
// happened in.
export const test = base.extend<{errors: string[]}>({
  errors: [
    async ({context, page, baseURL}, use) => {
      const errors: string[] = []
      const here = new URL(baseURL!).host
      const outside = (url: URL) => url.host !== here
      await context.route(outside, route => {
        errors.push(`outside request ${route.request().url()}`)
        return route.abort()
      })
      await context.routeWebSocket(outside, socket => {
        errors.push(`outside socket ${socket.url()}`)
        return socket.close()
      })
      page.on("pageerror", error => errors.push(error.message))
      // A page that did not load is the response its check reads; anything
      // else that fails to load, and anything else logged as an error, is a fault.
      page.on("console", message => {
        if (message.type() === "error" && !message.text().startsWith("Failed to load resource"))
          errors.push(message.text())
      })
      page.on("response", response => {
        if (response.status() >= 400 && response.request().resourceType() !== "document")
          errors.push(`${response.status()} ${response.url()}`)
      })
      await page.addInitScript(recordMoves)
      await use(errors)
      expect(errors, "page errors").toEqual([])
    },
    {auto: true},
  ],
})

export {expect}

type Recorded = Element & {pbMoves?: string[]; pbInside?: string[]}

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

/**
 * Starts keeping, on this element, the moves written onto anything inside it,
 * including pieces that are gone again by the time the check reads them.
 */
export const watchInside = (locator: Locator) =>
  locator.evaluate(root => {
    const kept: string[] = ((root as Recorded).pbInside = [])
    new MutationObserver(changes => {
      for (const change of changes) {
        const {transform, translate, opacity} = (change.target as HTMLElement).style
        if (change.target !== root && (transform || (translate && translate !== "none") || opacity))
          kept.push(`${transform} ${translate} ${opacity}`.trim())
      }
    }).observe(root, {subtree: true, attributes: true, attributeFilter: ["style"]})
  })

/** The moves written inside this element since `watchInside`. */
export const movesInside = (locator: Locator) => locator.evaluate(el => (el as Recorded).pbInside ?? [])

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
