# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: credits.phone.spec.ts >> Buy Credits opens from the Account page
- Location: test/browser/credits.phone.spec.ts:9:1

# Error details

```
Error: expect(locator).toBeAttached() failed

Locator: locator('.phx-connected').filter({ has: getByRole('button', { name: 'Buy Credits' }) }).first()
Expected: attached
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeAttached" locator('.phx-connected').filter({ has: getByRole('button', { name: 'Buy Credits' }) }).first() with timeout 5000ms
  - waiting for locator('.phx-connected').filter({ has: getByRole('button', { name: 'Buy Credits' }) }).first()

```

```yaml
- link "Skip to the main content":
  - /url: "#pb-content"
- banner:
  - link "Patchbay home":
    - /url: /
  - button "Search"
  - button "Menu"
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
          - time: 11 minutes ago
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
          - time: 11 minutes ago
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
          - time: 11 minutes ago
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
          - time: 11 minutes ago
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
  1  | import {type Locator, type Page} from "@playwright/test"
  2  | import {expect} from "./test"
  3  | 
  4  | // Buy Credits reads the wallet's USDC on Base. The walk's chain node is a closed port
  5  | // on this machine (config/dev.exs), so the dialog must open and say the balance is
  6  | // unavailable rather than hang or break. A walk whose server is pointed at a real
  7  | // node fails at its end, because the server's request leaves the machine
  8  | // (support/teardown.ts).
  9  | export async function balanceUnavailable(page: Page, open: Locator, {tap = false} = {}) {
  10 |   await expect(open).toBeVisible()
  11 |   // The buttons answer once their live views have connected, as they have for a
  12 |   // person by the time they reach for one.
> 13 |   await expect(page.locator(".phx-connected").filter({has: open}).first()).toBeAttached()
     |                                                                            ^ Error: expect(locator).toBeAttached() failed
  14 |   await expect(page.locator(".phx-connected #pb-credits")).toBeAttached()
  15 |   await (tap ? open.tap() : open.click())
  16 |   const dialog = page.getByRole("dialog", {name: "Buy Credits"})
  17 |   await expect(dialog).toBeVisible()
  18 |   await expect(dialog.getByRole("status", {name: "USDC in this wallet"})).toHaveText("unavailable")
  19 | }
  20 | 
```