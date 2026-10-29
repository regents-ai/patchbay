import {createPrivateKey, randomUUID, sign} from "node:crypto"
import {readFileSync} from "node:fs"
import {expect, test, watch} from "./support/test"

// Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
// Privy makes every person an Ethereum wallet when they sign in, and the page's
// bridge hands Privy's tokens over only once it exists (test/privy/provider.test.ts
// covers that check). Here the bridge is a stand-in that hands over tokens signed
// with this run's own Privy key (support/serve.sh), so the page's own Sign in posts
// them to this run's server: an email sign-in with the wallet Privy made signs in,
// and one with no wallet is still refused and says why. A Google sign-in leaves
// the page and Privy brings it back with ?privy_oauth_code=; that page finishes
// the sign-in by itself, with what was typed in the ask form kept.

const bridge = /\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/
const key = () => createPrivateKey(readFileSync(`test/browser/.auth/${process.env.PATCHBAY_DEV_PARTITION}/privy-key.pem`))
const email = {type: "email", address: "walk@example.com", lv: 1_000}
const made = {type: "wallet", address: "0x" + "7".repeat(40), chain_type: "ethereum", wallet_client_type: "privy", lv: 1_001}

// Privy's two tokens for one person, signed as Privy signs them (ES256).
function tokens(linkedAccounts: object[]) {
  const subject = `did:privy:walk-email-${randomUUID()}`
  const now = Math.floor(Date.now() / 1000)
  const claims = {iss: "privy.io", aud: "browser-walk-app", sub: subject, sid: subject, iat: now - 1, exp: now + 600}
  const jwt = (body: object) => {
    const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")
    const unsigned = `${part({alg: "ES256", typ: "JWT"})}.${part(body)}`
    const signature = sign("sha256", Buffer.from(unsigned), {key: key(), dsaEncoding: "ieee-p1363"})
    return `${unsigned}.${signature.toString("base64url")}`
  }
  return {ok: true, access: jwt(claims), identity: jwt({...claims, linked_accounts: JSON.stringify(linkedAccounts)})}
}

// The stand-in's sign-in answers with these tokens; every other export answers as
// a browser with no Privy sign-in does (support/test.ts).
async function signInAnswers(page: import("@playwright/test").Page, proof: object) {
  await standIn(page, `return ${JSON.stringify(proof)}`, `return ${JSON.stringify({ok: false, reason: "signed_out"})}`)
}

async function standIn(page: import("@playwright/test").Page, signIn: string, finishRedirectSignIn: string) {
  await page.route(bridge, route =>
    route.fulfill({
      contentType: "text/javascript",
      body: `
export async function signIn() { ${signIn} }
export async function finishRedirectSignIn() { ${finishRedirectSignIn} }
export async function signOut() {}
export async function activeWallet() { return {ok: false, reason: "signed_out"} }
export async function activeAddress() { return null }
export async function addFundsByCard() { return {ok: false, reason: "signed_out"} }
`,
    }),
  )
}

const signInButton = (page: import("@playwright/test").Page) =>
  page.locator("#account-signed-out").getByRole("button", {name: "Sign in"})

test("an email sign-in with the wallet Privy made signs in from the Account page", async ({page}) => {
  const problems = watch(page)
  await signInAnswers(page, tokens([email, made]))
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  await signInButton(page).click()
  expect((await answered).status()).toBe(200)

  await expect(page.locator("#account-signed-out")).toHaveCount(0)
  await expect(page.locator('[data-account-target="sign-in"]')).toHaveCount(0)
  await problems.expect()
})

test("an email sign-in with no wallet is refused and the page stays signed out", async ({page}) => {
  const problems = watch(page)
  await signInAnswers(page, tokens([email]))
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  await signInButton(page).click()
  const refusal = await answered
  expect(refusal.status()).toBe(422)
  expect((await refusal.json()).error.code).toBe("no_wallet")
  await expect(page.locator("#account-auth-status")).toHaveText("Your account has no wallet yet. Sign in again to get one.")

  await page.reload()
  await expect(signInButton(page)).toBeVisible()
  await problems.expect()
})

// Privy's Google button takes the whole page to Google, which brings it back to
// the page it left with ?privy_oauth_code=. Here the stand-in's signIn leaves the
// page that way, and the page it comes back to finishes the sign-in.
test("a Google sign-in that comes back to home signs in, with the ask form's draft kept", async ({page}, info) => {
  test.skip(info.project.name === "small phone", "checked at 1280 and 390")
  const problems = watch(page)
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({contentType: "application/json", body: JSON.stringify({status: "none", said: "", tools: [], directory: false})}))
  await standIn(
    page,
    `location.assign("/?privy_oauth_code=walk&privy_oauth_state=walk&privy_oauth_provider=google"); return new Promise(() => {})`,
    `return ${JSON.stringify(tokens([email, made]))}`,
  )
  await page.goto("/")
  await page.locator("#pb-ask > summary").click()
  await page.locator("#pb-fix-goal").fill("Booking tool refuses my date")

  const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  await page.locator("#pb-account [data-account-target='sign-in']").click()
  expect((await answered).status()).toBe(200)

  await expect(page.locator("#pb-account [data-account-target='sign-in']")).toHaveCount(0)
  await expect(page.locator("#pb-hero-form")).toHaveAttribute("data-pb-signed-in", "true")
  await expect(page.locator("#pb-fix-goal")).toHaveValue("Booking tool refuses my date")
  await problems.expect()
})
