# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: draft.spec.ts >> a draft on /hermes comes back after Publish asks for a sign-in
- Location: test/browser/draft.spec.ts:95:3

# Error details

```
Test timeout of 30000ms exceeded.
```

```
Error: expect(locator).toHaveAttribute(expected) failed

Locator: locator('#pb-hero-form')
Expected: "true"
Error: Test timeout of 30000ms exceeded.

Call log:
  - Expect "toHaveAttribute" locator('#pb-hero-form') with timeout 5000ms
  - waiting for locator('#pb-hero-form')

```

# Test source

```ts
  1   | import type {Locator, Page} from "@playwright/test"
  2   | import {email, made, privyTokens} from "./support/privy"
  3   | import {expect, formJoined, test, watch} from "./support/test"
  4   | 
  5   | // What a person types in the ask form comes back after they sign in, by the
  6   | // header's Sign in or by Publish, on home, an agent page and a site page's post
  7   | // window, and the form it comes back to is in view. Found on 29 Oct (the PB-13
  8   | // review): the form's own Sign in was gone, the post window covered the header's
  9   | // and opened Privy under itself, home put the draft back inside a closed "Ask a
  10  | // question", and a draft typed on /hermes turned up in another page's form.
  11  | 
  12  | // A Privy sign-in that goes through: the bridge hands over Privy's tokens for a
  13  | // new person with the wallet Privy made (support/privy.ts), and the page signs in
  14  | // with them as it always does, through /auth/csrf and the session address of this
  15  | // run's server, then reloads.
  16  | async function signInGoesThrough(page: Page) {
  17  |   const proof = JSON.stringify(privyTokens([email, made]))
  18  |   await page.route(/\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/, route =>
  19  |     route.fulfill({
  20  |       contentType: "text/javascript",
  21  |       body: `
  22  | export async function profile() { return {ok: false, status: null, error: {code: "authentication_required", outcome_unknown: false}} }
  23  | export async function signIn() { return ${proof} }
  24  | export async function finishRedirectSignIn() { return ${proof} }
  25  | export async function signOut() {}
  26  | export async function activeWallet() { return {ok: false, reason: "signed_out"} }
  27  | export async function activeAddress() { return null }
  28  | export async function addFundsByCard() { return {ok: false, reason: "signed_out"} }
  29  | `,
  30  |     }))
  31  | }
  32  | 
  33  | const DRAFT = {
  34  |   goal: "Booking tool refuses my date",
  35  |   site: "keyfleet.ai",
  36  |   details: "I tried book_table with 2025-11-01 and got invalid_date",
  37  |   tags: "booking",
  38  | }
  39  | 
  40  | async function fillDraft(form: Locator) {
  41  |   await form.locator("#pb-fix-goal").fill(DRAFT.goal)
  42  |   await form.locator("#pb-fix-site").fill(DRAFT.site)
  43  |   const details = form.locator("#pb-hero-details")
  44  |   if (!(await details.evaluate(element => (element as HTMLDetailsElement).open))) await details.locator("summary").click()
  45  |   await form.locator("#pb-hero-body").fill(DRAFT.details)
  46  |   await form.locator("#pb-hero-tags").fill(DRAFT.tags)
  47  | }
  48  | 
  49  | // Signed in now, every field back, and the form in view without a press.
  50  | async function expectDraftBack(page: Page) {
  51  |   const form = page.locator("#pb-hero-form")
> 52  |   await expect(form).toHaveAttribute("data-pb-signed-in", "true")
      |                      ^ Error: expect(locator).toHaveAttribute(expected) failed
  53  |   await expect(form.locator("#pb-fix-goal")).toBeVisible()
  54  |   await expect(form.locator("#pb-fix-goal")).toHaveValue(DRAFT.goal)
  55  |   await expect(form.locator("#pb-fix-site")).toHaveValue(DRAFT.site)
  56  |   await expect(form.locator("#pb-hero-body")).toHaveValue(DRAFT.details)
  57  |   await expect(form.locator("#pb-hero-tags")).toHaveValue(DRAFT.tags)
  58  | }
  59  | 
  60  | async function publish(page: Page, form: Locator) {
  61  |   await form.locator("[data-pb-preview]").filter({visible: true}).first().click()
  62  |   const button = form.locator("[data-pb-post]")
  63  |   await expect(button).toBeVisible()
  64  |   await Promise.all([page.waitForEvent("load"), button.click()])
  65  | }
  66  | 
  67  | // At 1280 and 390; the 320 phone takes the same paths as the 390 one. The
  68  | // site's tool check under the address field is answered here: it is not what
  69  | // these walks are about, and each real one counts against the walk's own
  70  | // connection, which the motion walks need for theirs.
  71  | test.beforeEach(async ({page}, info) => {
  72  |   test.skip(info.project.name === "small phone", "checked at 1280 and 390")
  73  |   await page.route(/\/fix-check\?/, route =>
  74  |     route.fulfill({
  75  |       contentType: "application/json",
  76  |       body: JSON.stringify({status: "none", said: "", tools: [], directory: false}),
  77  |     }))
  78  | })
  79  | 
  80  | for (const path of ["/", "/hermes"]) {
  81  |   test(`a draft on ${path} comes back after the header's Sign in`, async ({page}) => {
  82  |     await signInGoesThrough(page)
  83  |     const problems = watch(page)
  84  |     await page.goto(path)
  85  |     await formJoined(page)
  86  |     if (path === "/") await page.locator("#pb-ask > summary").click()
  87  |     await fillDraft(page.locator("#pb-hero-form"))
  88  |     const signIn = page.locator("[data-account-target='sign-in']").filter({visible: true})
  89  |     await expect(signIn).toHaveCount(1)
  90  |     await Promise.all([page.waitForEvent("load"), signIn.click()])
  91  |     await expectDraftBack(page)
  92  |     await problems.expect()
  93  |   })
  94  | 
  95  |   test(`a draft on ${path} comes back after Publish asks for a sign-in`, async ({page}) => {
  96  |     await signInGoesThrough(page)
  97  |     const problems = watch(page)
  98  |     await page.goto(path)
  99  |     await formJoined(page)
  100 |     if (path === "/") await page.locator("#pb-ask > summary").click()
  101 |     await fillDraft(page.locator("#pb-hero-form"))
  102 |     await publish(page, page.locator("#pb-hero-form"))
  103 |     await expectDraftBack(page)
  104 |     await problems.expect()
  105 |   })
  106 | }
  107 | 
  108 | test.describe("a site page's post window", () => {
  109 |   const openWindow = async (page: Page) => {
  110 |     await page.goto("/keyfleet.ai")
  111 |     await formJoined(page)
  112 |     await page.locator("a[href='#pb-site-post']").first().click()
  113 |     const postWindow = page.locator("#pb-site-post")
  114 |     await expect(postWindow).toBeVisible()
  115 |     return postWindow
  116 |   }
  117 | 
  118 |   test("Publish closes the window for the sign-in, and the window opens again with the draft", async ({page}) => {
  119 |     await signInGoesThrough(page)
  120 |     const problems = watch(page)
  121 |     const postWindow = await openWindow(page)
  122 |     await fillDraft(postWindow.locator("#pb-hero-form"))
  123 |     await publish(page, postWindow.locator("#pb-hero-form"))
  124 |     await expect(page.locator("#pb-site-post")).toBeVisible()
  125 |     await expectDraftBack(page)
  126 |     await problems.expect()
  127 |   })
  128 | 
  129 |   test("the window's own Sign in is the one in view, and the draft comes back", async ({page}) => {
  130 |     await signInGoesThrough(page)
  131 |     const problems = watch(page)
  132 |     const postWindow = await openWindow(page)
  133 |     await fillDraft(postWindow.locator("#pb-hero-form"))
  134 |     const signIn = page.locator("[data-account-target='sign-in']").filter({visible: true})
  135 |     await expect(signIn).toHaveCount(2)
  136 |     // The window covers the header's, so the window's is the one a press reaches.
  137 |     const reached = await page.evaluate(() =>
  138 |       [...document.querySelectorAll<HTMLElement>("[data-account-target='sign-in']")]
  139 |         .filter(button => {
  140 |           const box = button.getBoundingClientRect()
  141 |           if (box.width === 0) return false
  142 |           const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)
  143 |           return hit !== null && button.contains(hit)
  144 |         })
  145 |         .map(button => button.closest("#pb-site-post") !== null))
  146 |     expect(reached).toEqual([true])
  147 |     await Promise.all([page.waitForEvent("load"), postWindow.locator("[data-account-target='sign-in']").click()])
  148 |     await expect(page.locator("#pb-site-post")).toBeVisible()
  149 |     await expectDraftBack(page)
  150 |     await problems.expect()
  151 |   })
  152 | 
```