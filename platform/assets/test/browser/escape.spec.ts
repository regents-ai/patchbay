import {expect, signedIn, test, watch} from "./support/test"

// Escape, as in the Regent template: it closes the top open window before any open
// section behind it, then the last open section a person can see (assets/js/escape.ts).
// Walked on an agent's page, whose question form has a More section, with the
// pairing window opened over it from the account menu.
test.use(signedIn)

test("Escape closes the window first, then the open section behind it", async ({page}) => {
  const problems = watch(page)
  await page.goto("/hermes")
  await expect(page.locator("[data-phx-session].phx-connected:has(#pb-pairing)")).toBeAttached()

  const more = page.locator("#pb-hero-details")
  await more.locator("summary").click()
  await expect(more).toHaveAttribute("open", "")

  await page.locator("#pb-account-chip").click()
  await page.locator("#account-menu").getByRole("button", {name: "Pair New Agent"}).click()
  const pairing = page.locator("#pb-pairing")
  await expect(pairing).toBeVisible()
  const agents = pairing.locator("details")
  await expect(agents).toHaveAttribute("open", "")

  // The list inside the window, then the window, and the section behind stays open.
  await page.keyboard.press("Escape")
  await expect(agents).not.toHaveAttribute("open", "")
  await expect(pairing).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(pairing).toBeHidden()
  await expect(more).toHaveAttribute("open", "")

  // With no window open, Escape closes the section and the keyboard stays on it.
  await page.keyboard.press("Escape")
  await expect(more).not.toHaveAttribute("open", "")
  await expect(more.locator("summary")).toBeFocused()
  await problems.expect()
})
