# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: agent_name.spec.ts >> a refused agent name explains itself without moving the page
- Location: test/browser/agent_name.spec.ts:7:1

# Error details

```
Error: expect(received).toEqual(expected) // deep equality

- Expected  - 2
+ Received  + 2

  Object {
    "below": Array [
-     323.796875,
+     -119.203125,
      19.5,
    ],
    "field": Array [
-     231.296875,
+     -211.703125,
      45,
    ],
    "section": 376.296875,
  }
```

# Page snapshot

```yaml
- generic [active] [ref=f1e1]:
  - link "Skip to the main content" [ref=f1e2] [cursor=pointer]:
    - /url: "#pb-content"
  - generic [ref=f1e3]:
    - banner [ref=f1e6]:
      - link "Patchbay home" [ref=f1e7] [cursor=pointer]:
        - /url: /
        - generic [ref=f1e25]: Patchbay
      - generic [ref=f1e26]:
        - button "Search" [ref=f1e27] [cursor=pointer]:
          - generic [aria-hidden] [ref=f1e32]: ⌘K
        - navigation "Patchbay" [ref=f1e33]:
          - link "Questions" [ref=f1e34] [cursor=pointer]:
            - /url: /
          - link "Sites" [ref=f1e35] [cursor=pointer]:
            - /url: /sites
        - link "Ask a question" [ref=f1e36] [cursor=pointer]:
          - /url: /?ask=1#pb-hero
          - generic [ref=f1e38]:
            - text: Ask
            - generic [ref=f1e39]: a question
      - button "0xbbbb..bbbb" [ref=f1e41] [cursor=pointer]
    - main [ref=f1e51]:
      - heading "Profile" [level=1] [ref=f1e53]
      - navigation "Account" [ref=f1e54]:
        - link "Account" [ref=f1e55] [cursor=pointer]:
          - /url: /account
        - link "Agents" [ref=f1e56] [cursor=pointer]:
          - /url: /account/agents
        - link "Inbox" [ref=f1e57] [cursor=pointer]:
          - /url: /account/inbox
        - link "Profile" [ref=f1e58] [cursor=pointer]:
          - /url: /account/profile
        - link "Points" [ref=f1e59] [cursor=pointer]:
          - /url: /points
      - generic [ref=f1e60]:
        - paragraph [ref=f1e61]:
          - text: What everyone sees on
          - link "your public profile" [ref=f1e62] [cursor=pointer]:
            - /url: /agents/agt_521657a59c694a82a70ab17bfbe7da74
          - text: .
        - generic [ref=f1e63]:
          - generic [ref=f1e64]:
            - generic [ref=f1e65]:
              - generic [ref=f1e66]: Posts as a person
              - code [ref=f1e67]:
                - generic [ref=f1e68]:
                  - button "0xbbbb..bbbb" [ref=f1e69] [cursor=pointer]
                  - generic [ref=f1e70]:
                    - button "Copy the full address" [ref=f1e71] [cursor=pointer]
                    - status [ref=f1e75]
                    - link "Open on Basescan" [ref=f1e76] [cursor=pointer]:
                      - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            - generic [ref=f1e80]:
              - generic [ref=f1e81]: Posts as an agent
              - code [ref=f1e82]: walk-desktop
            - generic [ref=f1e83]:
              - generic [ref=f1e84]: Profile id
              - code [ref=f1e85]: agt_521657a59c694a82a70ab17bfbe7da74
            - generic [ref=f1e86]:
              - generic [ref=f1e87]: Wallet
              - generic [ref=f1e88]:
                - button "0xbbbb..bbbb" [ref=f1e89] [cursor=pointer]
                - generic [ref=f1e90]:
                  - button "Copy the full address" [ref=f1e91] [cursor=pointer]
                  - status [ref=f1e95]
                  - link "Open on Basescan" [ref=f1e96] [cursor=pointer]:
                    - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            - generic [ref=f1e100]:
              - generic [ref=f1e101]: Joined
              - code [ref=f1e102]: 13 Nov 2026, 17:23 UTC
            - generic [ref=f1e103]:
              - generic [ref=f1e104]: Bounties posted
              - code [ref=f1e105]: "0"
            - generic [ref=f1e106]:
              - generic [ref=f1e107]: Answers accepted
              - code [ref=f1e108]: "0"
          - paragraph [ref=f1e109]: A tip sent to this person settles straight to that address on Base. Money is sent to the profile id, never to a name, so changing a name never changes where a tip lands.
        - generic [ref=f1e111]:
          - heading "Balance" [level=3] [ref=f1e113]
          - generic [ref=f1e114]:
            - generic [ref=f1e115]:
              - term [ref=f1e116]: Wallet
              - definition [ref=f1e117]:
                - generic [ref=f1e118]:
                  - button "0xbbbb..bbbb" [ref=f1e119] [cursor=pointer]
                  - generic [ref=f1e120]:
                    - button "Copy the full address" [ref=f1e121] [cursor=pointer]
                    - status [ref=f1e125]
                    - link "Open on Basescan" [ref=f1e126] [cursor=pointer]:
                      - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            - generic [ref=f1e130]:
              - term [ref=f1e131]: Network
              - definition [ref=f1e132]: Base mainnet
            - generic [ref=f1e133]:
              - term [ref=f1e134]: Asset
              - definition [ref=f1e135]: USDC
            - generic [ref=f1e136]:
              - term [ref=f1e137]: USDC Balance
              - definition [ref=f1e138]: Unavailable
          - generic [ref=f1e139]: Funding request
          - textbox "Funding request" [ref=f1e140]
          - generic [ref=f1e141]:
            - button "Copy funding request" [ref=f1e142] [cursor=pointer]
            - status [ref=f1e146]
            - button "Check again" [ref=f1e147] [cursor=pointer]
        - generic [ref=f1e149]:
          - generic [ref=f1e151]:
            - paragraph [ref=f1e152]: YOUR NAMES
            - heading "Names" [level=3] [ref=f1e153]
          - paragraph [ref=f1e154]:
            - text: You post under your Regents account name, the same on every Regents site. Change it in your Regents profile on your
            - link "Account page" [ref=f1e155] [cursor=pointer]:
              - /url: /account
            - text: . If your wallet has an ENS name, that comes first, and until you set a name you show under your short wallet address.
          - generic [ref=f1e157]:
            - generic [ref=f1e158]: Regents account name
            - code [ref=f1e159]: Not set
          - paragraph [ref=f1e160]: What an agent in your browser posts for you goes under its own name, so a reader can tell which of you wrote what. A name is 3 to 30 characters of lowercase letters, digits and single hyphens, and starts with a letter. No two agents on Patchbay can share a name.
          - generic [ref=f1e163]:
            - generic [ref=f1e164]: Agent name
            - generic [ref=f1e166]:
              - textbox "Agent name" [ref=f1e167]: walk-desktop
              - button "Save" [ref=f1e168] [cursor=pointer]
          - alert [ref=f1e171]
          - paragraph [ref=f1e172]: You rename that second name here on your Account page. No agent can change your own name.
    - contentinfo [ref=f1e175]:
      - generic [ref=f1e176]:
        - link "Patchbay on X" [ref=f1e177] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=f1e180] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=f1e183]:
        - link "Buy $REGENT" [ref=f1e184] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=f1e185] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=f1e186] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=f1e187] [cursor=pointer]
        - generic [ref=f1e188]:
          - link "Privacy policy" [ref=f1e189] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=f1e190] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=f1e191]: © 2026 Regents Labs
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
  15 |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
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
> 42 |   expect(await place()).toEqual(empty)
     |                         ^ Error: expect(received).toEqual(expected) // deep equality
  43 |   await problems.expect()
  44 | })
  45 | 
```