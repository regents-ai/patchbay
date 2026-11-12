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
  await expect(pairingWindow(page)).toHaveAttribute("data-settled", "")
}

// A person opens the dropdown, unless it is already open, and presses the agent's
// name; the radio's label carries it. The choice closes the list, so the radio is
// looked for hidden too when its check is read.
async function choose(page: Page, scope: Locator, agent: string) {
  const pick = scope.locator("details")
  const radio = scope.getByRole("radio", {name: agent, exact: true, includeHidden: true})
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
const top = (locator: Locator) => locator.evaluate(element => element.getBoundingClientRect().top)
const picture = (page: Page) => box(page).locator(".rg-account__stage")
const agents = (page: Page) => dropdown(page).locator("[data-panel='list']")

// The page's clock, held still so a move in the list can be pressed half way.
async function holdClock(page: Page) {
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1000))
}

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

    // By keyboard: the summary opens the list, an arrow chooses the next agent, and
    // focus comes back to the summary once the list closes.
    await dropdown(page).locator("summary").focus()
    await page.keyboard.press("Enter")
    await expect(dropdown(page)).toHaveAttribute("open", "")
    await box(page).getByRole("radio", {name: "Hermes", exact: true}).focus()
    await page.keyboard.press("ArrowRight")
    await expect(dropdown(page)).not.toHaveAttribute("open", "")
    await expect(dropdown(page).locator("summary")).toBeFocused()
    await expect(dropdown(page).locator("summary")).not.toContainText("Hermes")
    await problems.expect()
  })

  // The picture sits in a band at most half the height of a 16:9 box, sharp and
  // centred, and choosing another agent moves nothing under it (Sean, 11 Nov 2026).
  test("the agent's picture sits in a low band, and choosing moves nothing under it", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    const steps = box(page).locator("ol")
    const waiting = await top(steps)

    await choose(page, box(page), "Hermes")
    await expect(message(page)).toContainText(/Pairing code/)
    const band = await picture(page).evaluate(stage => {
      const outer = stage.getBoundingClientRect()
      const image = stage.querySelector("img")!
      const inner = image.getBoundingClientRect()
      return {
        width: outer.width,
        height: outer.height,
        offCentre: Math.max(
          Math.abs(inner.left + inner.width / 2 - (outer.left + outer.width / 2)),
          Math.abs(inner.top + inner.height / 2 - (outer.top + outer.height / 2)),
        ),
        inside: inner.top >= outer.top && inner.bottom <= outer.bottom,
        sharp: image.naturalWidth >= inner.width * devicePixelRatio,
      }
    })
    expect(band.height).toBeLessThanOrEqual((band.width * 9) / 16 / 2)
    expect(band).toMatchObject({inside: true, sharp: true})
    expect(band.offCentre).toBeLessThan(1)
    expect(await top(steps)).toBeCloseTo(waiting, 1)

    await choose(page, box(page), "Any agent")
    await expect(message(page)).toContainText(/Pairing code/)
    expect(await height(picture(page))).toBeCloseTo(band.height, 1)
    expect(await top(steps)).toBeCloseTo(waiting, 1)
    await problems.expect()
  })

  // The list drops in and leaves with a short move, and a press during it always
  // counts: on an agent as it comes in, and on what is under the list as it leaves.
  // The page's clock is held, so the press lands half way through each move.
  test("a press during the list's move always counts", async ({page}) => {
    const problems = watch(page)
    await page.clock.install()
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await choose(page, box(page), "OpenAI Codex")
    await expect(message(page)).toContainText(/Pairing code/)
    const first = await message(page).innerText()

    // Held 30 ms into the entrance, an agent still on its way in takes the press.
    await holdClock(page)
    await dropdown(page).locator("summary").click()
    await page.clock.runFor(30)
    const hermes = box(page).locator("label", {hasText: "Hermes"})
    await expect(dropdown(page)).not.toHaveAttribute("data-settled")
    expect(await hermes.evaluate(label => Number(getComputedStyle(label).opacity))).toBeLessThan(1)
    await hermes.click({force: true})
    await expect(box(page).getByRole("radio", {name: "Hermes", exact: true, includeHidden: true})).toBeChecked()
    await expect(message(page)).not.toHaveText(first)
    const second = await message(page).innerText()

    // Held 30 ms into its exit, the list still covers the new-code button, which
    // takes the press.
    await expect(agents(page)).toHaveAttribute("data-leaving", "")
    await page.clock.runFor(30)
    await expect(agents(page)).toBeVisible()
    expect(await agents(page).evaluate(list => Number(getComputedStyle(list).opacity))).toBeLessThan(1)
    await box(page).getByRole("button", {name: "Make a new code"}).click()
    await expect(message(page)).not.toHaveText(second)
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)

    // Each move ends within 200 ms and leaves nothing behind.
    await page.clock.runFor(170)
    await expect(agents(page)).not.toHaveAttribute("data-leaving")
    await expect(agents(page)).toBeHidden()
    await dropdown(page).locator("summary").click()
    await page.clock.runFor(200)
    await expect(dropdown(page)).toHaveAttribute("data-settled", "")
    await expect(agents(page)).not.toHaveAttribute("style")
    await problems.expect()
  })

  // With reduced motion asked for, the list opens and closes at once.
  test("with reduced motion the list opens and closes at once", async ({page}) => {
    const problems = watch(page)
    await page.emulateMedia({reducedMotion: "reduce"})
    await page.clock.install()
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await choose(page, box(page), "OpenAI Codex")
    await expect(message(page)).toContainText(/Pairing code/)

    await holdClock(page)
    await dropdown(page).locator("summary").click()
    await expect(dropdown(page)).toHaveAttribute("data-settled", "")
    await expect(box(page).locator("label", {hasText: "Hermes"})).toHaveCSS("opacity", "1")
    await box(page).locator("label", {hasText: "Hermes"}).click()
    await expect(dropdown(page)).not.toHaveAttribute("open", "")
    await expect(agents(page)).not.toHaveAttribute("data-leaving")
    await expect(agents(page)).toBeHidden()
    await problems.expect()
  })

  // A reconnecting page sends the pairing form back with no agent picked, and a
  // submit can come before a choice. Neither may crash the pairing box (Sentinel,
  // 23 Oct 2026, from Patchbay's error mail).
  test("the pairing form with nothing chosen leaves the box as it is", async ({page}) => {
    const problems = watch(page)
    const crashes: string[] = []
    page.on("websocket", socket =>
      socket.on("framereceived", frame => {
        if (String(frame.payload).includes('"phx_error"')) crashes.push(String(frame.payload).slice(0, 120))
      }),
    )
    await page.goto("/account/agents")
    await ready(page)
    await openWindow(page)
    await expect(box(page).getByRole("radio", {checked: true})).toHaveCount(0)

    await box(page).getByRole("radio").first().dispatchEvent("input")
    await box(page).evaluate(element => (element as HTMLFormElement).requestSubmit())

    await choose(page, box(page), "Hermes")
    await expect(message(page)).toContainText(/Pairing code:\s*\S{12,}/)
    expect(crashes).toEqual([])
    await problems.expect()
  })

  // Unpair asks in the site's own window, worded with what it does. Cancel changes
  // nothing and hands the keyboard back to the button.
  test("Unpair asks first, and Cancel keeps the agent", async ({page}) => {
    const problems = watch(page)
    await page.goto("/account/agents")
    await ready(page)
    const unpair = page.locator("#account-agents").getByRole("button", {name: /^Unpair /}).first()
    const name = (await unpair.getAttribute("aria-label"))!.replace(/^Unpair /, "")
    const paired = await page.locator("#account-agents").getByRole("button", {name: /^Unpair /}).count()

    await unpair.click()
    const asking = page.locator("#rg-confirm")
    await expect(asking).toBeVisible()
    await expect(asking).toContainText(`Unpair ${name}?`)
    await expect(asking.getByRole("button", {name: "Unpair", exact: true})).toBeVisible()
    await asking.getByRole("button", {name: "Cancel"}).click()
    await expect(asking).toBeHidden()
    await expect(unpair).toBeFocused()
    await expect(page.locator("#account-agents").getByRole("button", {name: /^Unpair /})).toHaveCount(paired)
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
