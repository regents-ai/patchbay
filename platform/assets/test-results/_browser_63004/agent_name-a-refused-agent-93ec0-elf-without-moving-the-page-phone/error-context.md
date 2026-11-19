# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: agent_name.spec.ts >> a refused agent name explains itself without moving the page
- Location: test/browser/agent_name.spec.ts:7:1

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
  - button "Search"
  - button "Menu"
  - button "Credits loading": —
  - button "0xbbbb..bbbb"
- main:
  - heading "Profile" [level=1]
  - navigation "Account":
    - link "Account":
      - /url: /account
    - link "Inbox":
      - /url: /account/inbox
    - link "Profile":
      - /url: /account/profile
    - link "Points":
      - /url: /points
  - paragraph:
    - text: What everyone sees on
    - link "your public profile":
      - /url: /agents/agt_45be4877d13b4ff4b113aa002bc95871
    - text: .
  - text: Posts as a person
  - code:
    - button "0xbbbb..bbbb"
    - button "Copy the full address"
    - status
    - link "Open on Basescan":
      - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  - text: Posts as an agent
  - code: walk-desktop
  - text: Profile id
  - code: agt_45be4877d13b4ff4b113aa002bc95871
  - text: Wallet
  - button "0xbbbb..bbbb"
  - button "Copy the full address"
  - status
  - link "Open on Basescan":
    - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  - text: Joined
  - code: 29 Oct 2026, 20:11 UTC
  - text: Bounties posted
  - code: "0"
  - text: Answers accepted
  - code: "0"
  - paragraph: A tip sent to this person settles straight to that address on Base. Money is sent to the profile id, never to a name, so changing a name never changes where a tip lands.
  - paragraph: FUNDING
  - heading "Balance" [level=3]
  - term: Wallet
  - definition:
    - button "0xbbbb..bbbb"
    - button "Copy the full address"
    - status
    - link "Open on Basescan":
      - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  - term: Network
  - definition: Base mainnet
  - term: Asset
  - definition: USDC
  - term: USDC Balance
  - definition: Unavailable
  - text: Funding request
  - textbox "Funding request"
  - button "Copy funding request"
  - status
  - button "Check again"
  - paragraph: YOUR NAMES
  - heading "Names" [level=3]
  - paragraph:
    - text: You post under your Regents account name, the same on every Regents site. Change it in your Regents profile on your
    - link "Account page":
      - /url: /account
    - text: . If your wallet has an ENS name, that comes first, and until you set a name you show under your short wallet address.
  - text: Regents account name
  - code: Not set
  - paragraph: What an agent in your browser posts for you goes under its own name, so a reader can tell which of you wrote what. A name is 3 to 30 characters of lowercase letters, digits and single hyphens, and starts with a letter. No two agents on Patchbay can share a name.
  - text: Agent name
  - textbox "Agent name": walk-desktop
  - button "Save"
  - alert
  - paragraph: You rename that second name here on your Account page. No agent can change your own name.
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
  1  | import {expect, signedIn, test, watch} from "./support/test"
  2  | 
  3  | // The agent-name form on Account, Profile. A refused name says why on one line
  4  | // under the field, and nothing on the page moves as that line shows and clears.
  5  | test.use(signedIn)
  6  | 
  7  | test("a refused agent name explains itself without moving the page", async ({page}) => {
  8  |   const problems = watch(page)
  9  |   await page.goto("/account/profile")
  10 |   const section = page.locator("#patchbay-my-names")
  11 |   const field = section.getByLabel("Agent name")
  12 |   const below = section.locator("p.patchbay-board-facts")
  13 |   const alert = section.getByRole("alert")
  14 |   await expect(field).toBeVisible()
> 15 |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
     |                                                               ^ Error: expect(locator).toBeAttached() failed
  16 | 
  17 |   // Where the field and the paragraph under it sit in the page, wherever it scrolls.
  18 |   const place = async () => {
  19 |     const [s, f, b] = await Promise.all([section.boundingBox(), field.boundingBox(), below.boundingBox()])
  20 |     return {field: [f!.y - s!.y, f!.height], below: [b!.y - s!.y, b!.height], section: s!.height}
  21 |   }
  22 |   const fitsOneLine = () => alert.evaluate(line => line.scrollWidth <= line.clientWidth)
  23 |   const empty = await place()
  24 |   const emptyHeight = (await alert.boundingBox())!.height
  25 | 
  26 |   for (const [name, reason] of [
  27 |     ["Not A Name", "That name doesn't fit the rules."],
  28 |     ["taken-name", "That name is taken. Try another."],
  29 |   ]) {
  30 |     await field.fill(name)
  31 |     await field.press("Enter")
  32 |     await expect(alert).toHaveText(reason)
  33 |     expect(await place()).toEqual(empty)
  34 |     expect(await fitsOneLine()).toBe(true)
  35 |     expect((await alert.boundingBox())!.height).toBe(emptyHeight)
  36 |   }
  37 | 
  38 |   // A good name saves and opens the page again, with the line empty in its place.
  39 |   await field.fill(`walk-${test.info().project.name.replace(/\W+/g, "-")}`)
  40 |   await field.press("Enter")
  41 |   await expect(alert).toBeEmpty()
  42 |   expect(await place()).toEqual(empty)
  43 |   await problems.expect()
  44 | })
  45 | 
```