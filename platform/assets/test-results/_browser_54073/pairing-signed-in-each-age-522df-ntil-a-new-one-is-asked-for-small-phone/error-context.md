# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: pairing.spec.ts >> signed in >> each agent keeps its own code until a new one is asked for
- Location: test/browser/pairing.spec.ts:295:3

# Error details

```
Error: expect(locator).toContainText(expected) failed

Locator: locator('form#pb-pairing-box').locator('details').locator('summary')
Timeout: 5000ms
- Expected substring  - 1
+ Received string     + 6

- OpenAI Codex
+
+       
+   
+
+       Hermes
+     

Call log:
  - Expect "toContainText" locator('form#pb-pairing-box').locator('details').locator('summary') with timeout 5000ms
  - waiting for locator('form#pb-pairing-box').locator('details').locator('summary')
    14 × locator resolved to <summary data-phx-loc="493" aria-label="Agent: Hermes">…</summary>
       - unexpected value "
      
  

      Hermes
    "

```

```yaml
- text: Hermes
```

# Test source

```ts
  1   | import type {Locator, Page} from "@playwright/test"
  2   | import {expect, signedIn, test, watch} from "./support/test"
  3   | 
  4   | // Pairing an agent, the way a person does it, as in the Regent template's walk:
  5   | // Pair New Agent on the Agents page opens the pairing window over the page, where
  6   | // they choose their agent from the dropdown and copy its message. The agent guides'
  7   | // Pair New Agent leads to /pair, which holds the same box.
  8   | 
  9   | const pairingWindow = (page: Page) => page.locator("#pb-pairing")
  10  | const box = (page: Page) => page.locator("form#pb-pairing-box")
  11  | const message = (page: Page) => page.locator("#pb-pairing-box pre")
  12  | const dropdown = (page: Page) => box(page).locator("details")
  13  | 
  14  | const pairButton = (page: Page) =>
  15  |   page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"})
  16  | 
  17  | // The page and the header's live part answer once both have connected, as they have
  18  | // for a person by the time they reach for them.
  19  | async function ready(page: Page) {
  20  |   await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  21  |   await expect(page.locator("[data-phx-session].phx-connected:has(#pb-pairing)")).toBeAttached()
  22  | }
  23  | 
  24  | // Opened, and done opening, so what is measured is where it rests.
  25  | async function openWindow(page: Page) {
  26  |   await pairButton(page).click()
  27  |   await expect(pairingWindow(page)).toBeVisible()
  28  |   await expect(pairingWindow(page)).toHaveAttribute("data-settled", "")
  29  | }
  30  | 
  31  | // A person opens the dropdown, unless it is already open, and presses the agent's
  32  | // name; the radio's label carries it. The choice closes the list, so the radio is
  33  | // looked for hidden too when its check is read.
  34  | async function choose(page: Page, scope: Locator, agent: string) {
  35  |   const pick = scope.locator("details")
  36  |   const radio = scope.getByRole("radio", {name: agent, exact: true, includeHidden: true})
  37  |   if (!(await pick.evaluate(details => (details as HTMLDetailsElement).open))) {
  38  |     await pick.locator("summary").click()
  39  |   }
  40  |   await radio.locator("xpath=ancestor::label").click()
  41  |   await expect(radio).toBeChecked()
> 42  |   await expect(pick.locator("summary")).toContainText(agent)
      |                                         ^ Error: expect(locator).toContainText(expected) failed
  43  | }
  44  | 
  45  | // The box's height on screen. The centred window can place it a tiny fraction of a
  46  | // pixel differently between reads, so heights are compared to a twentieth of a pixel.
  47  | const height = (locator: Locator) => locator.evaluate(element => element.getBoundingClientRect().height)
  48  | const top = (locator: Locator) => locator.evaluate(element => element.getBoundingClientRect().top)
  49  | const picture = (page: Page) => box(page).locator(".rg-account__stage")
  50  | const agents = (page: Page) => dropdown(page).locator("[data-panel='list']")
  51  | 
  52  | // The page's clock, held still so a move in the list can be pressed half way.
  53  | async function holdClock(page: Page) {
  54  |   await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1000))
  55  | }
  56  | 
  57  | // Opens the list by its summary while the clock is held. The browser says the
  58  | // list opened a moment after the press, and the list starts its move then, so
  59  | // the held clock is run only once the move has begun.
  60  | async function dropIn(page: Page) {
  61  |   await dropdown(page).locator("summary").click()
  62  |   await expect(agents(page)).toHaveAttribute("style", /opacity/)
  63  | }
  64  | 
  65  | test.describe("signed in", () => {
  66  |   test.use(signedIn)
  67  | 
  68  |   // Every press opens the window (Keyfleet, 27 Oct 2026: pressed a second time, Pair
  69  |   // New Agent did nothing a person could see).
  70  |   test("Pair New Agent on the Agents page opens the pairing window, every press", async ({page}) => {
  71  |     const problems = watch(page)
  72  |     await page.goto("/account/agents")
  73  |     await ready(page)
  74  |     await openWindow(page)
  75  |     await expect(page).toHaveURL(/\/account\/agents$/)
  76  |     await pairingWindow(page).getByRole("button", {name: "Close"}).click()
  77  |     await expect(pairingWindow(page)).toBeHidden()
  78  |     await expect(pairButton(page)).toBeFocused()
  79  | 
  80  |     // With the agents listed, the first Escape closes the list and the next the window.
  81  |     await openWindow(page)
  82  |     await page.keyboard.press("Escape")
  83  |     await expect(dropdown(page)).not.toHaveAttribute("open", "")
  84  |     await expect(pairingWindow(page)).toBeVisible()
  85  |     await page.keyboard.press("Escape")
  86  |     await expect(pairingWindow(page)).toBeHidden()
  87  | 
  88  |     // A press on the dimmed page around the window closes it too.
  89  |     await openWindow(page)
  90  |     await page.mouse.click(2, 2)
  91  |     await expect(pairingWindow(page)).toBeHidden()
  92  |     await problems.expect()
  93  |   })
  94  | 
  95  |   // The window opens on the list of agents with the keyboard on the dropdown; a
  96  |   // choice closes the list and shows the message to paste.
  97  |   test("the window opens on the agents, and a choice closes the list", async ({page}) => {
  98  |     const problems = watch(page)
  99  |     await page.goto("/account/agents")
  100 |     await ready(page)
  101 |     await openWindow(page)
  102 |     await expect(dropdown(page)).toHaveAttribute("open", "")
  103 |     await expect(dropdown(page).locator("summary")).toBeFocused()
  104 |     await expect(box(page).getByRole("radio", {name: "Hermes", exact: true})).toBeVisible()
  105 | 
  106 |     await choose(page, box(page), "Hermes")
  107 |     await expect(dropdown(page)).not.toHaveAttribute("open", "")
  108 |     // The agent learns it pairs with the person's Regents Labs account, and on which site.
  109 |     await expect(message(page)).toContainText(/^Pair with my Regents Labs account on localhost\n/)
  110 |     await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
  111 | 
  112 |     // By keyboard: the summary opens the list, an arrow chooses the next agent, and
  113 |     // focus comes back to the summary once the list closes.
  114 |     await dropdown(page).locator("summary").focus()
  115 |     await page.keyboard.press("Enter")
  116 |     await expect(dropdown(page)).toHaveAttribute("open", "")
  117 |     await box(page).getByRole("radio", {name: "Hermes", exact: true}).focus()
  118 |     await page.keyboard.press("ArrowRight")
  119 |     await expect(dropdown(page)).not.toHaveAttribute("open", "")
  120 |     await expect(dropdown(page).locator("summary")).toBeFocused()
  121 |     await expect(dropdown(page).locator("summary")).not.toContainText("Hermes")
  122 |     await problems.expect()
  123 |   })
  124 | 
  125 |   // The picture sits in a band at most half the height of a 16:9 box, sharp and
  126 |   // centred, and choosing another agent moves nothing under it (Sean, 11 Nov 2026).
  127 |   test("the agent's picture sits in a low band, and choosing moves nothing under it", async ({page}) => {
  128 |     const problems = watch(page)
  129 |     await page.goto("/account/agents")
  130 |     await ready(page)
  131 |     await openWindow(page)
  132 |     const steps = box(page).locator("ol")
  133 |     const waiting = await top(steps)
  134 | 
  135 |     await choose(page, box(page), "Hermes")
  136 |     await expect(message(page)).toContainText(/Pairing code/)
  137 |     const band = await picture(page).evaluate(stage => {
  138 |       const outer = stage.getBoundingClientRect()
  139 |       const image = stage.querySelector("img")!
  140 |       const inner = image.getBoundingClientRect()
  141 |       return {
  142 |         width: outer.width,
```