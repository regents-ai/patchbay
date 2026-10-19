import {type Locator, type Page} from "@playwright/test"
import {expect, test as walk} from "./test"

// The motion checks. Every page in them records each move written onto any
// element, and an error the page logs, a part of the page that fails to load,
// or a socket that reaches outside this machine fails the check it happened in
// (outside requests already fail it, support/test.ts).
export const test = walk.extend<{faults: void}>({
  faults: [
    async ({context, page, baseURL}, use) => {
      const faults: string[] = []
      const here = new URL(baseURL!).host
      await context.routeWebSocket(
        url => url.host !== here,
        socket => {
          faults.push(`outside socket ${socket.url()}`)
          return socket.close()
        },
      )
      // A page that did not load is the response its check reads; anything
      // else that fails to load, and anything else logged as an error, is a fault.
      page.on("console", message => {
        if (message.type() === "error" && !message.text().startsWith("Failed to load resource"))
          faults.push(message.text())
      })
      page.on("response", response => {
        if (response.status() >= 400 && response.request().resourceType() !== "document")
          faults.push(`${response.status()} ${response.url()}`)
      })
      await page.addInitScript(recordMoves)
      await use()
      expect(faults, "page faults").toEqual([])
    },
    {auto: true},
  ],
})

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

/** Waits for the live page to connect. */
export const connected = (page: Page) => page.locator("[data-phx-main].phx-connected").waitFor()

/** Presses a control the way this project's reader does: a tap on the phone, a click with a mouse. */
export const press = (locator: Locator, isMobile: boolean) => (isMobile ? locator.tap() : locator.click())

export {expect}
