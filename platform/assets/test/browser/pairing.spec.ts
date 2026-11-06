import type {Locator, Page} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// Pairing an agent, the way a person does it, as in the Regent template's walk:
// Pair New Agent on the Agents page opens the pairing window over the page, where
// they choose their agent from the dropdown and copy its message. The agent guides'
// Pair New Agent leads to /pair, which holds the same box.

const pairingWindow = (page: Page) => page.locator("#pb-pairing")
const box = (page: Page) => page.locator("form#pb-pairing-box")
const message = (page: Page) => page.locator("#pb-pairing-box pre")
const dropdown = (page: Page) => box(page).locator("details")

const pairButton = (page: Page) =>
  page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"})

// The page and the header's live part answer once both have connected, as they have
// for a person by the time they reach for them.
async function ready(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("[data-phx-session].phx-connected:has(#pb-pairing)")).toBeAttached()
}

// Opened, and done opening, so what is measured is where it rests.
async function openWindow(page: Page) {
  await pairButton(page).click()
  await expect(pairingWindow(page)).toBeVisible()
  await expect.poll(() => pairingWindow(page).evaluate(element => element.getAnimations().length)).toBe(0)
}

// A person opens the dropdown, unless it is already open, and presses the agent's
// name; the radio's label carries it.
async function choose(page: Page, scope: Locator, agent: string) {
  const pick = scope.locator("details")
  const radio = scope.getByRole("radio", {name: agent, exact: true})
  if (!(await pick.evaluate(details => (details as HTMLDetailsElement).open))) {
    await pick.locator("summary").click()
  }
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()
  await expect(pick.locator("summary")).toContainText(agent)
}

// The box's height on screen. The centred window can place it a tiny fraction of a
// pixel differently between reads, so heights are compared to a twentieth of a pixel.
const height = (locator: Locator) => locator.evaluate(element => element.getBoundingClientRect().height)

test.describe("signed in", () => {
  test.use(signedIn)

  // Every press opens the window (Keyfleet, 27 Oct 2026: pressed a second time, Pair
  // New Agent did nothing a person could see).
  test("Pair New Agent on the Agents page opens the pairing window, every press", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await expect(page).toHaveURL(/\/account\/agents$/)
    await pairingWindow(page).getByRole("button", {name: "Close"}).click()
    await expect(pairingWindow(page)).toBeHidden()
    await expect(pairButton(page)).toBeFocused()

    // With the agents listed, the first Escape closes the list and the next the window.
    await openWindow(page)
    await page.keyboard.press("Escape")
    await expect(dropdown(page)).not.toHaveAttribute("open", "")
    await expect(pairingWindow(page)).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(pairingWindow(page)).toBeHidden()

    // A press on the dimmed page around the window closes it too.
    await openWindow(page)
    await page.mouse.click(2, 2)
    await expect(pairingWindow(page)).toBeHidden()
    await problems.expect()
  })

  // The window opens on the list of agents with the keyboard on the dropdown; a
  // choice closes the list and shows the message to paste.
  test("the window opens on the agents, and a choice closes the list", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await expect(dropdown(page)).toHaveAttribute("open", "")
    await expect(dropdown(page).locator("summary")).toBeFocused()
    await expect(box(page).getByRole("radio", {name: "Hermes", exact: true})).toBeVisible()

    await choose(page, box(page), "Hermes")
    await expect(dropdown(page)).not.toHaveAttribute("open", "")
    // The agent learns it pairs with the person's Regents Labs account, and on which site.
    await expect(message(page)).toContainText(/^Pair with my Regents Labs account on localhost\n/)
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    await problems.expect()
  })

  // Choosing never changes the window's height (founder, 2026-10-07).
  test("the window keeps one height whatever is chosen", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    const before = await height(box(page))
    await choose(page, box(page), "Hermes")
    await expect(message(page)).toContainText(/Pairing code/)
    expect(await height(box(page))).toBeCloseTo(before, 1)
    await choose(page, box(page), "Any agent")
    await expect(message(page)).toContainText(/Pairing code/)
    expect(await height(box(page))).toBeCloseTo(before, 1)
    await problems.expect()
  })

  test("each agent keeps its own code until a new one is asked for", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await expect(message(page)).toHaveCount(0)

    await choose(page, box(page), "Hermes")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    const first = await message(page).innerText()

    await choose(page, box(page), "OpenAI Codex")
    await expect(message(page)).not.toHaveText(first)
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)

    // Coming back shows the same code, so a message already pasted still works.
    await choose(page, box(page), "Hermes")
    await expect(message(page)).toHaveText(first)

    await box(page).getByRole("button", {name: "Make a new code"}).click()
    await expect(message(page)).not.toHaveText(first)
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    await problems.expect()
  })

  // The agent guides link here with the page to send the agent on to; the message
  // ends there, and an address that is not on this site is left out.
  test("/pair sends the agent on to a page on this site, and to nowhere else", async ({page}) => {
    const problems = watch(page)
    await page.goto("/pair?to=/agents")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(page.locator("#pair-start a")).toHaveAttribute("href", "/agents")
    const pairBox = page.locator("form#pair-pairing-box")
    await choose(page, pairBox, "Hermes")
    // The message's last line names the page at the site's own address.
    await expect(page.locator("#pair-pairing-box pre")).toContainText(/https?:\/\/\S+\/agents$/)
    await problems.expect()

    await page.goto("/pair?to=//elsewhere.example")
    await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
    await expect(page.locator("#pair-start")).toHaveCount(0)
    await choose(page, pairBox, "Hermes")
    await expect(page.locator("#pair-pairing-box pre")).toContainText(/Pairing code/)
    await expect(page.locator("#pair-pairing-box pre")).not.toContainText("elsewhere.example")
    await problems.expect()
  })
})

test("/pair, signed out, asks the visitor to sign in", async ({page}) => {
  const problems = watch(page)
  await page.goto("/pair")
  await expect(page.getByRole("heading", {level: 1, name: "Pair New Agent"})).toBeVisible()
  await expect(page.locator("#pair-signed-out").getByRole("button", {name: "Sign in"})).toBeVisible()
  await expect(page.locator("#pair-pairing-box")).toHaveCount(0)
  await problems.expect()
})
