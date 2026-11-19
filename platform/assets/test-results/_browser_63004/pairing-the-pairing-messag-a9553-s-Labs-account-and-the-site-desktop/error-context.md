# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: pairing.spec.ts >> the pairing message names the Regents Labs account and the site
- Location: test/browser/pairing.spec.ts:7:1

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
  - button "Credits loading": — Credits
  - button "0xbbbb..bbbb"
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
  - region "Your account":
    - paragraph: Your account
    - heading "0xbbbb..bbbb Copy the full address Open on Basescan" [level=2]:
      - button "0xbbbb..bbbb"
      - button "Copy the full address"
      - status
      - link "Open on Basescan":
        - /url: https://basescan.org/address/0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  - region "Agents About paired agents":
    - heading "Agents About paired agents" [level=2]:
      - text: Agents
      - button "About paired agents"
    - list:
      - listitem:
        - paragraph:
          - strong: Phone Agent
        - button "0x4444..4444"
        - button "Copy the full address"
        - status
        - link "Open on Basescan":
          - /url: https://basescan.org/address/0x4444444444444444444444444444444444444444
        - button "Unpair Phone Agent": Unpair
        - paragraph:
          - text: Hermes · Last check-in
          - time: 4 minutes ago
      - listitem:
        - paragraph:
          - strong: Desktop Agent
        - button "0x3333..3333"
        - button "Copy the full address"
        - status
        - link "Open on Basescan":
          - /url: https://basescan.org/address/0x3333333333333333333333333333333333333333
        - button "Unpair Desktop Agent": Unpair
        - paragraph:
          - text: Hermes · Last check-in
          - time: 4 minutes ago
      - listitem:
        - paragraph:
          - strong: Walk Agent
        - button "0x2222..2222"
        - button "Copy the full address"
        - status
        - link "Open on Basescan":
          - /url: https://basescan.org/address/0x2222222222222222222222222222222222222222
        - button "Unpair Walk Agent": Unpair
        - paragraph:
          - text: Hermes · Last check-in
          - time: 4 minutes ago
      - listitem:
        - paragraph:
          - strong: Spare Agent
        - button "0x1111..1111"
        - button "Copy the full address"
        - status
        - link "Open on Basescan":
          - /url: https://basescan.org/address/0x1111111111111111111111111111111111111111
        - button "Unpair Spare Agent": Unpair
        - paragraph:
          - text: Hermes · Last check-in
          - time: 4 minutes ago
    - link "Pair New Agent":
      - /url: "#account-pairing"
  - region "Pair New Agent":
    - heading "Pair New Agent" [level=2]
    - status:
      - paragraph: Choose type of agent below to get pairing message.
      - status
    - group "Choose the agent to pair":
      - text: Choose the agent to pair
      - radio "Any agent"
      - text: Any agent
      - radio "OpenAI Codex"
      - text: OpenAI Codex
      - radio "Grok Bot"
      - text: Grok Bot
      - radio "Muse"
      - text: Muse
      - radio "Hermes"
      - text: Hermes
      - radio "Dots"
      - text: Dots
      - radio "IronClaw"
      - text: IronClaw
      - radio "OpenClaw"
      - text: OpenClaw
      - radio "Claude Code"
      - text: Claude Code
      - radio "Pi"
      - text: Pi
  - region "Credits":
    - heading "Credits" [level=2]
    - status: Loading…
    - term: Available
    - definition: Loading…
    - term: Held
    - definition: Loading…
    - button "Buy Credits"
    - paragraph:
      - link "Manage Credits on regents.sh":
        - /url: https://regents.sh/account
      - link "Credits help":
        - /url: /credits-help
  - heading "Profile" [level=2]
  - text: Public Display Name
  - textbox "Public Display Name"
  - text: The name people see for you.
  - button "About your Public Display Name"
  - button "Save"
  - status
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
  3  | // Pairing an agent on the Account page: Pair New Agent under the agents leads to the
  4  | // page's pairing box, and choosing an agent gives the message to paste to it.
  5  | test.use(signedIn)
  6  | 
  7  | test("the pairing message names the Regents Labs account and the site", async ({page}) => {
  8  |   const problems = watch(page)
  9  |   await page.goto("/account")
> 10 |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
     |                                                               ^ Error: expect(locator).toBeAttached() failed
  11 |   await page.locator("#account-agents").getByRole("link", {name: "Pair New Agent"}).click()
  12 | 
  13 |   const pairing = page.locator("#account-pairing")
  14 |   await expect(pairing).toBeInViewport()
  15 |   const radio = pairing.getByRole("radio", {name: "Hermes", exact: true})
  16 |   await radio.locator("xpath=ancestor::label").click()
  17 |   await expect(radio).toBeChecked()
  18 | 
  19 |   const message = page.locator("#account-pairing-box pre")
  20 |   await expect(message).toContainText(/^Pair with my Regents Labs account on localhost\n/)
  21 |   await expect(message).toContainText(/Pairing code:\s*\S{12,}/)
  22 |   await problems.expect()
  23 | })
  24 | 
```