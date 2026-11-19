# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: theme_switch.spec.ts >> signed in >> the account menu's theme switch turns the theme by press and by key, and the choice holds
- Location: test/browser/theme_switch.spec.ts:52:3

# Error details

```
Error: expect(locator).toBeAttached() failed

Locator: locator('[data-phx-session].phx-connected:has(#account-menu)')
Expected: attached
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeAttached" locator('[data-phx-session].phx-connected:has(#account-menu)') with timeout 5000ms
  - waiting for locator('[data-phx-session].phx-connected:has(#account-menu)')

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
  - heading "Agents" [level=1]
  - navigation "Account":
    - link "Account":
      - /url: /account
    - link "Agents":
      - /url: /account/agents
    - link "Inbox":
      - /url: /account/inbox
    - link "Profile":
      - /url: /account/profile
    - link "Points":
      - /url: /points
  - region "Paired About paired agents":
    - heading "Paired About paired agents" [level=2]:
      - text: Paired
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
          - time: 1 minute ago
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
          - time: 1 minute ago
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
          - time: 1 minute ago
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
          - time: 1 minute ago
    - button "Pair New Agent"
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
    - link "Privacy policy":
      - /url: /privacy
    - link "Terms of use":
      - /url: /terms
  - paragraph: © 2026 Regents Labs
```

# Test source

```ts
  1   | import type {Page} from "@playwright/test"
  2   | import {expect, signedIn, test, watch} from "./support/test"
  3   | 
  4   | // The light and dark switch (PatchbayWeb.ThemeSwitch.theme_toggle/1), as in the
  5   | // Regent template. It is a real switch, on for the light theme: a press, Space or
  6   | // Enter turns the page's theme, each one once, and the choice holds over a reload
  7   | // and a live page change. Signed in it is a row of the account menu, which keeps
  8   | // its size whichever way the switch is turned, and opening the menu moves nothing
  9   | // on the page. With no account menu it sits in the header.
  10  | 
  11  | const menu = (page: Page) => page.locator("#account-menu")
  12  | 
  13  | // The theme on screen: the page's own once chosen, otherwise the device's.
  14  | const showing = (page: Page) =>
  15  |   page.evaluate(() => {
  16  |     const theme = document.documentElement.dataset.theme
  17  |     if (theme === "light" || theme === "dark") return theme
  18  |     return matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"
  19  |   })
  20  | 
  21  | const stated = (page: Page) => page.evaluate(() => document.documentElement.dataset.theme)
  22  | 
  23  | test.describe("signed in", () => {
  24  |   test.use(signedIn)
  25  | 
  26  |   const toggle = (page: Page) => menu(page).getByRole("switch", {name: "Light theme"})
  27  | 
  28  |   // The header's live part answers once it has connected, as it has for a person
  29  |   // by the time they reach for it.
  30  |   async function ready(page: Page) {
> 31  |     await expect(page.locator("[data-phx-session].phx-connected:has(#account-menu)")).toBeAttached()
      |                                                                                       ^ Error: expect(locator).toBeAttached() failed
  32  |   }
  33  | 
  34  |   // Opened, and done dropping in, so what is measured is where it rests.
  35  |   async function openMenu(page: Page) {
  36  |     await page.locator("#pb-account-chip").click()
  37  |     await expect(menu(page)).toBeVisible()
  38  |     await expect.poll(() => menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
  39  |   }
  40  | 
  41  |   // The switch says what the page shows: on for light, off for dark.
  42  |   async function expectTheme(page: Page, theme: "light" | "dark") {
  43  |     await expect.poll(() => showing(page)).toBe(theme)
  44  |     await expect(toggle(page)).toHaveAttribute("aria-checked", String(theme === "light"))
  45  |   }
  46  | 
  47  |   const size = async (page: Page) => {
  48  |     const box = (await menu(page).boundingBox())!
  49  |     return {width: box.width, height: box.height}
  50  |   }
  51  | 
  52  |   test("the account menu's theme switch turns the theme by press and by key, and the choice holds", async ({page, hasTouch}) => {
  53  |     const problems = watch(page)
  54  |     await page.goto("/account/agents")
  55  |     await ready(page)
  56  | 
  57  |     // The account menu, closed or open, is the only place the switch is.
  58  |     await expect(page.getByRole("switch", {name: "Light theme", includeHidden: true})).toHaveCount(1)
  59  | 
  60  |     const content = page.locator("#pb-content")
  61  |     const before = await content.boundingBox()
  62  |     await openMenu(page)
  63  |     expect(await content.boundingBox()).toEqual(before)
  64  |     if (hasTouch) expect((await toggle(page).boundingBox())!.height).toBeGreaterThanOrEqual(44)
  65  | 
  66  |     const first = await showing(page)
  67  |     const other = first === "light" ? "dark" : "light"
  68  |     await expectTheme(page, first)
  69  |     const opened = await size(page)
  70  | 
  71  |     await toggle(page).click()
  72  |     await expectTheme(page, other)
  73  |     await expect(menu(page)).toBeVisible()
  74  |     expect(await size(page)).toEqual(opened)
  75  | 
  76  |     await toggle(page).focus()
  77  |     await page.keyboard.press("Space")
  78  |     await expectTheme(page, first)
  79  |     await page.keyboard.press("Enter")
  80  |     await expectTheme(page, other)
  81  |     expect(await size(page)).toEqual(opened)
  82  | 
  83  |     await page.reload()
  84  |     await ready(page)
  85  |     await expect.poll(() => stated(page)).toBe(other)
  86  |     await openMenu(page)
  87  |     await expectTheme(page, other)
  88  | 
  89  |     // Manage Account is a live page change: the document stays and restates its theme.
  90  |     await page.evaluate(() => void ((window as {pbStayed?: boolean}).pbStayed = true))
  91  |     await menu(page).getByRole("link", {name: "Manage Account"}).click()
  92  |     await expect(page).toHaveURL(/\/account$/)
  93  |     expect(await page.evaluate(() => (window as {pbStayed?: boolean}).pbStayed)).toBe(true)
  94  |     await expect.poll(() => stated(page)).toBe(other)
  95  |     await openMenu(page)
  96  |     await expectTheme(page, other)
  97  |     await problems.expect()
  98  |   })
  99  | })
  100 | 
  101 | // Signed out there is no account menu, so on a desktop the switch sits in the
  102 | // header: of a page no live view draws, and of a live page. Each press turns it
  103 | // once. It stays off phones signed out (Sean, 16 Oct).
  104 | test.describe("signed out", () => {
  105 |   for (const path of ["/sites", "/points"]) {
  106 |     test(`the header's theme switch on ${path} turns the theme once a press, and the choice holds`, async ({page, isMobile}) => {
  107 |       test.skip(isMobile, "signed out, a phone has no theme switch")
  108 |       const problems = watch(page)
  109 |       await page.goto(path)
  110 |       await expect(page.locator("[data-phx-session].phx-connected").first()).toBeAttached()
  111 |       const toggle = page.getByRole("switch", {name: "Light theme"})
  112 |       await expect(toggle).toHaveCount(1)
  113 |       await expect(page.locator("header.pb-masthead").getByRole("switch")).toBeVisible()
  114 | 
  115 |       const first = await showing(page)
  116 |       const other = first === "light" ? "dark" : "light"
  117 |       await expect(toggle).toHaveAttribute("aria-checked", String(first === "light"))
  118 | 
  119 |       await toggle.click()
  120 |       await expect.poll(() => showing(page)).toBe(other)
  121 |       await expect(toggle).toHaveAttribute("aria-checked", String(other === "light"))
  122 | 
  123 |       await toggle.focus()
  124 |       await page.keyboard.press("Space")
  125 |       await expect.poll(() => showing(page)).toBe(first)
  126 |       await expect(toggle).toHaveAttribute("aria-checked", String(first === "light"))
  127 |       await page.keyboard.press("Enter")
  128 |       await expect.poll(() => showing(page)).toBe(other)
  129 |       await expect(toggle).toHaveAttribute("aria-checked", String(other === "light"))
  130 | 
  131 |       await page.reload()
```