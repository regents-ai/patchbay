# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: sign_in.spec.ts >> an email sign-in with the wallet Privy made signs in from the Account page
- Location: test/browser/sign_in.spec.ts:59:1

# Error details

```
Error: expect(locator).toBeAttached() failed

Locator: locator('[data-phx-main].phx-connected')
Expected: attached
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeAttached" locator('[data-phx-main].phx-connected') with timeout 5000ms
  - waiting for locator('[data-phx-main].phx-connected')

```

```yaml
- link "Skip to the main content":
  - /url: "#pb-content"
- banner:
  - link "Patchbay home":
    - /url: /
    - text: Patchbay
  - button "Search"
  - navigation "Patchbay":
    - link "Questions":
      - /url: /
    - link "Sites":
      - /url: /sites
    - link "Offers":
      - /url: /offers
  - link "Ask a question":
    - /url: /?ask=1#pb-hero
  - button "Light theme on. Switch to dark theme."
  - button "Sign in"
- main:
  - heading "Account" [level=1]
  - navigation "Account":
    - link "Account":
      - /url: /account
    - link "Inbox":
      - /url: /account/inbox
    - link "Profile":
      - /url: /account/profile
    - link "Points":
      - /url: /points
  - paragraph: Sign in to see your account.
  - button "Sign in"
- contentinfo:
  - link "Patchbay on X":
    - /url: https://x.com/regents_sh
  - link "Patchbay on GitHub":
    - /url: https://github.com/regents-ai
  - navigation "About Patchbay":
    - link "Buy $REGENT":
      - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
    - link "About":
      - /url: /about
    - link "Developer docs":
      - /url: /docs
    - button "Agent guide"
    - link "Contact":
      - /url: /contact
    - link "Privacy policy":
      - /url: /privacy
    - link "Terms of use":
      - /url: /terms
  - paragraph: © 2026 Regents Labs
```

# Test source

```ts
  1   | import {createPrivateKey, randomUUID, sign} from "node:crypto"
  2   | import {readFileSync} from "node:fs"
  3   | import {expect, test, watch} from "./support/test"
  4   | 
  5   | // Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
  6   | // Privy makes every person an Ethereum wallet when they sign in, and the page's
  7   | // bridge hands Privy's tokens over only once it exists (test/privy/provider.test.ts
  8   | // covers that check). Here the bridge is a stand-in that hands over tokens signed
  9   | // with this run's own Privy key (support/serve.sh), so the page's own Sign in posts
  10  | // them to this run's server: an email sign-in with the wallet Privy made signs in,
  11  | // and one with no wallet is still refused and says why. A Google sign-in leaves
  12  | // the page and Privy brings it back with ?privy_oauth_code=; that page finishes
  13  | // the sign-in by itself, with what was typed in the ask form kept.
  14  | 
  15  | const bridge = /\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/
  16  | const key = () => createPrivateKey(readFileSync(`test/browser/.auth/${process.env.PATCHBAY_DEV_PARTITION}/privy-key.pem`))
  17  | const email = {type: "email", address: "walk@example.com", lv: 1_000}
  18  | const made = {type: "wallet", address: "0x" + "7".repeat(40), chain_type: "ethereum", wallet_client_type: "privy", lv: 1_001}
  19  | 
  20  | // Privy's two tokens for one person, signed as Privy signs them (ES256).
  21  | function tokens(linkedAccounts: object[]) {
  22  |   const subject = `did:privy:walk-email-${randomUUID()}`
  23  |   const now = Math.floor(Date.now() / 1000)
  24  |   const claims = {iss: "privy.io", aud: "browser-walk-app", sub: subject, sid: subject, iat: now - 1, exp: now + 600}
  25  |   const jwt = (body: object) => {
  26  |     const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")
  27  |     const unsigned = `${part({alg: "ES256", typ: "JWT"})}.${part(body)}`
  28  |     const signature = sign("sha256", Buffer.from(unsigned), {key: key(), dsaEncoding: "ieee-p1363"})
  29  |     return `${unsigned}.${signature.toString("base64url")}`
  30  |   }
  31  |   return {ok: true, access: jwt(claims), identity: jwt({...claims, linked_accounts: JSON.stringify(linkedAccounts)})}
  32  | }
  33  | 
  34  | // The stand-in's sign-in answers with these tokens; every other export answers as
  35  | // a browser with no Privy sign-in does (support/test.ts).
  36  | async function signInAnswers(page: import("@playwright/test").Page, proof: object) {
  37  |   await standIn(page, `return ${JSON.stringify(proof)}`, `return ${JSON.stringify({ok: false, reason: "signed_out"})}`)
  38  | }
  39  | 
  40  | async function standIn(page: import("@playwright/test").Page, signIn: string, finishRedirectSignIn: string) {
  41  |   await page.route(bridge, route =>
  42  |     route.fulfill({
  43  |       contentType: "text/javascript",
  44  |       body: `
  45  | export async function signIn() { ${signIn} }
  46  | export async function finishRedirectSignIn() { ${finishRedirectSignIn} }
  47  | export async function signOut() {}
  48  | export async function activeWallet() { return {ok: false, reason: "signed_out"} }
  49  | export async function activeAddress() { return null }
  50  | export async function addFundsByCard() { return {ok: false, reason: "signed_out"} }
  51  | `,
  52  |     }),
  53  |   )
  54  | }
  55  | 
  56  | const signInButton = (page: import("@playwright/test").Page) =>
  57  |   page.locator("#account-signed-out").getByRole("button", {name: "Sign in"})
  58  | 
  59  | test("an email sign-in with the wallet Privy made signs in from the Account page", async ({page}) => {
  60  |   const problems = watch(page)
  61  |   await signInAnswers(page, tokens([email, made]))
  62  |   await page.goto("/account")
> 63  |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
      |                                                               ^ Error: expect(locator).toBeAttached() failed
  64  | 
  65  |   const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  66  |   await signInButton(page).click()
  67  |   expect((await answered).status()).toBe(200)
  68  | 
  69  |   await expect(page.locator("#account-signed-out")).toHaveCount(0)
  70  |   await expect(page.locator('[data-account-target="sign-in"]')).toHaveCount(0)
  71  |   await problems.expect()
  72  | })
  73  | 
  74  | test("an email sign-in with no wallet is refused and the page stays signed out", async ({page}) => {
  75  |   const problems = watch(page)
  76  |   await signInAnswers(page, tokens([email]))
  77  |   await page.goto("/account")
  78  |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  79  | 
  80  |   const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  81  |   await signInButton(page).click()
  82  |   const refusal = await answered
  83  |   expect(refusal.status()).toBe(422)
  84  |   expect((await refusal.json()).error.code).toBe("no_wallet")
  85  |   await expect(page.locator("#account-auth-status")).toHaveText("Your account has no wallet yet. Sign in again to get one.")
  86  | 
  87  |   await page.reload()
  88  |   await expect(signInButton(page)).toBeVisible()
  89  |   await problems.expect()
  90  | })
  91  | 
  92  | // Privy's Google button takes the whole page to Google, which brings it back to
  93  | // the page it left with ?privy_oauth_code=. Here the stand-in's signIn leaves the
  94  | // page that way, and the page it comes back to finishes the sign-in.
  95  | test("a Google sign-in that comes back to home signs in, with the ask form's draft kept", async ({page}, info) => {
  96  |   test.skip(info.project.name === "small phone", "checked at 1280 and 390")
  97  |   const problems = watch(page)
  98  |   await page.route(/\/fix-check\?/, route =>
  99  |     route.fulfill({contentType: "application/json", body: JSON.stringify({status: "none", said: "", tools: [], directory: false})}))
  100 |   await standIn(
  101 |     page,
  102 |     `location.assign("/?privy_oauth_code=walk&privy_oauth_state=walk&privy_oauth_provider=google"); return new Promise(() => {})`,
  103 |     `return ${JSON.stringify(tokens([email, made]))}`,
  104 |   )
  105 |   await page.goto("/")
  106 |   await page.locator("#pb-ask > summary").click()
  107 |   await page.locator("#pb-fix-goal").fill("Booking tool refuses my date")
  108 | 
  109 |   const answered = page.waitForResponse(response => response.url().endsWith("/auth/privy/session"))
  110 |   await page.locator("#pb-account [data-account-target='sign-in']").click()
  111 |   expect((await answered).status()).toBe(200)
  112 | 
  113 |   await expect(page.locator("#pb-account [data-account-target='sign-in']")).toHaveCount(0)
  114 |   await expect(page.locator("#pb-hero-form")).toHaveAttribute("data-pb-signed-in", "true")
  115 |   await expect(page.locator("#pb-fix-goal")).toHaveValue("Booking tool refuses my date")
  116 |   await problems.expect()
  117 | })
  118 | 
```