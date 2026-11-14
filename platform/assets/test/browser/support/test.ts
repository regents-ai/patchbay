import {test as base, expect, type BrowserContext, type Page} from "@playwright/test"

// The walk never leaves this machine. The page's sign-in bridge, the only part
// that talks to Privy, is answered by a stand-in that holds no Privy sign-in;
// any other outside address is refused and fails the check that reached for it.
const bridge = /^\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/
// The same exports as assets/js/privy_bridge.tsx, each answering as a browser with
// no Privy sign-in does.
const signedOut = {ok: false, reason: "signed_out"}
const standIn = `
export async function profile() { return ${JSON.stringify({ok: false, status: null, error: {code: "authentication_required", outcome_unknown: false}})} }
export async function signIn() { return ${JSON.stringify(signedOut)} }
export async function finishRedirectSignIn() { return ${JSON.stringify(signedOut)} }
export async function signOut() {}
export async function activeWallet() { return ${JSON.stringify(signedOut)} }
export async function activeAddress() { return null }
export async function addFundsByCard() { return ${JSON.stringify(signedOut)} }
`

// Keeps a browser's pages on this machine, and lists what they reached for
// outside it. Every check's own browser has it; a check that opens a second
// one gives it the same.
export async function keepOnThisMachine(context: BrowserContext, baseURL: string) {
  const site = new URL(baseURL).host
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
  return outside
}

export const test = base.extend<{onThisMachine: void}>({
  onThisMachine: [async ({context, baseURL}, use) => {
    const outside = await keepOnThisMachine(context, baseURL!)
    await use()
    expect(outside, "requests that left the machine").toEqual([])
  }, {auto: true}],
})

// A person's saved sign-in, written by sign_in.exs into this run's own folder
// before the server starts.
export const signInFile = (person: string) => `test/browser/.auth/${process.env.PATCHBAY_DEV_PARTITION}/${person}.json`

// The walk's person.
export const signedIn = {storageState: signInFile("person")}

// The post form's live part has joined (PatchbayWeb.PostFormLive): what is typed
// and pressed from now on reaches it.
export const formJoined = (page: Page) =>
  page.locator("[data-phx-session].phx-connected:has(#pb-hero-form)").waitFor({state: "attached"})

// What a broken page shows: an uncaught error, or content wider than the screen.
// The width is read once the page has loaded: a page a link has only just opened
// may not have its styles yet, and is laid out as plain HTML that no visitor sees.
export function watch(page: Page) {
  const problems: string[] = []
  page.on("pageerror", error => problems.push(`page error: ${error.message}`))
  return {
    expect: async () => {
      await page.waitForLoadState()
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      if (overflow > 0) problems.push(`content is ${overflow}px wider than the screen`)
      expect(problems).toEqual([])
    },
  }
}

export {expect}
