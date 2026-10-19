import {test as base, expect, type Page} from "@playwright/test"

// The walk never leaves this machine. The page's sign-in bridge, the only part
// that talks to Privy, is answered by a stand-in that holds no Privy sign-in;
// any other outside address is refused and fails the check that reached for it.
const bridge = /^\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/
const standIn = "export async function startPrivyBridge() { return {request: async () => {}} }\n"

export const test = base.extend<{onThisMachine: void}>({
  onThisMachine: [async ({context, baseURL}, use) => {
    const site = new URL(baseURL!).host
    const outside: string[] = []
    await context.route(() => true, route => {
      const url = new URL(route.request().url())
      if (url.host !== site) {
        outside.push(`${route.request().method()} ${url.origin}${url.pathname}`)
        return route.abort("blockedbyclient")
      }
      if (bridge.test(url.pathname))
        return route.fulfill({contentType: "text/javascript", body: standIn})
      return route.continue()
    })
    await use()
    expect(outside, "requests that left the machine").toEqual([])
  }, {auto: true}],
})

// The walk's person, signed in by sign_in.exs before the server starts.
export const signedIn = {storageState: "test/browser/.auth/person.json"}

// What a broken page shows: an uncaught error, or content wider than the screen.
export function watch(page: Page) {
  const problems: string[] = []
  page.on("pageerror", error => problems.push(`page error: ${error.message}`))
  return {
    expect: async () => {
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      if (overflow > 0) problems.push(`content is ${overflow}px wider than the screen`)
      expect(problems).toEqual([])
    },
  }
}

export {expect}
