# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: layers.spec.ts >> signed in, at 390 wide >> a tip in the page stays under the open account menu
- Location: test/browser/layers.spec.ts:20:3

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
          - time: 2 minutes ago
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
          - time: 2 minutes ago
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
          - time: 2 minutes ago
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
          - time: 2 minutes ago
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
  3  | // Found on 28 Oct (the design chief's live check): at 390 wide, a tip in the page
  4  | // (an agent's card, the Offers question mark, the Wallet Bench filter) drew over the
  5  | // header and over the account's panel opened from it, because the page content made
  6  | // no stacking place of its own. The page content is one place now, under the header
  7  | // and the account menu; the motion lab's drawer, sheet and note are lifted above the
  8  | // whole page by the browser, as a window is.
  9  | 
  10 | // What sits at the centre of a box: inside which of the named parts it lands.
  11 | const landsIn = (page: import("@playwright/test").Page, box: {x: number; y: number; width: number; height: number}, selector: string) =>
  12 |   page.evaluate(
  13 |     ({x, y, selector}) => document.elementFromPoint(x, y)?.closest(selector) !== null,
  14 |     {x: box.x + box.width / 2, y: box.y + box.height / 2, selector},
  15 |   )
  16 | 
  17 | test.describe("signed in, at 390 wide", () => {
  18 |   test.use(signedIn)
  19 | 
  20 |   test("a tip in the page stays under the open account menu", async ({page}) => {
  21 |     const problems = watch(page)
  22 |     await page.setViewportSize({width: 390, height: 844})
  23 |     await page.goto("/account")
> 24 |     await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
     |                                                                 ^ Error: expect(locator).toBeAttached() failed
  25 |     await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
  26 | 
  27 |     const menu = page.locator("#account-menu")
  28 |     await page.locator("#pb-account-chip").click()
  29 |     await expect(menu).toBeVisible()
  30 |     await expect.poll(() => menu.evaluate(element => element.getAnimations().length)).toBe(0)
  31 | 
  32 |     // A tip shown at the top of the page content, under the open menu.
  33 |     const panel = (await menu.boundingBox())!
  34 |     await page.evaluate(left => {
  35 |       const content = document.querySelector<HTMLElement>("#pb-content")!
  36 |       const host = document.createElement("span")
  37 |       host.className = "pb-offers-tip-host"
  38 |       host.style.display = "block"
  39 |       host.style.marginInlineStart = `${left - content.getBoundingClientRect().left}px`
  40 |       host.innerHTML =
  41 |         '<span class="pb-offers-tip"><span id="walk-tip" role="tooltip" class="pb-offers-tip-text" style="display: block">A tip</span></span>'
  42 |       content.prepend(host)
  43 |     }, panel.x + 16)
  44 |     const tip = (await page.locator("#walk-tip").boundingBox())!
  45 |     expect(tip.x + tip.width / 2).toBeGreaterThan(panel.x)
  46 |     expect(tip.x + tip.width / 2).toBeLessThan(panel.x + panel.width)
  47 |     expect(tip.y + tip.height / 2).toBeGreaterThan(panel.y)
  48 |     expect(tip.y + tip.height / 2).toBeLessThan(panel.y + panel.height)
  49 | 
  50 |     expect(await landsIn(page, tip, "#account-menu")).toBe(true)
  51 |     await problems.expect()
  52 |   })
  53 | })
  54 | 
  55 | test("the motion lab's drawer opens over the header", async ({page}) => {
  56 |   const problems = watch(page)
  57 |   await page.goto("/animations")
  58 |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  59 | 
  60 |   // Opened from the keyboard, so it is there at once.
  61 |   await page.getByRole("button", {name: "Open the drawer"}).press("Enter")
  62 |   const drawer = page.locator("#lab-drawer")
  63 |   await expect(drawer).toBeVisible()
  64 |   // The header scrolls with the page; the drawer stays where it opened.
  65 |   await page.evaluate(() => window.scrollTo(0, 0))
  66 | 
  67 |   const header = (await page.locator(".pb-frame > :first-child").boundingBox())!
  68 |   const box = (await drawer.boundingBox())!
  69 |   const overlap = {x: box.x, y: header.y, width: Math.min(box.width, header.width), height: header.height}
  70 |   expect(await landsIn(page, overlap, "#lab-drawer")).toBe(true)
  71 | 
  72 |   await page.keyboard.press("Escape")
  73 |   await expect(drawer).toBeHidden()
  74 |   await problems.expect()
  75 | })
  76 | 
```