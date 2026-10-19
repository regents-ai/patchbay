import {expect, signedIn, test, watch} from "./support/test"

// The Buy Credits dialog reads the wallet's USDC on Base. The walk's chain node is a
// closed port on this machine (config/dev.exs), so the dialog must open and say the
// balance is unavailable rather than hang or break. A walk whose server is pointed
// at a real node fails at its end, because the server's request leaves the machine
// (support/teardown.ts).
test.use(signedIn)

test("Buy Credits says the balance is unavailable when Base can't be reached", async ({page}) => {
  // The header's balance, which opens Buy Credits, shows from 900px wide.
  test.skip(test.info().project.name !== "desktop", "the header leaves the balance out on a phone")
  const problems = watch(page)
  await page.goto("/")
  const balance = page.getByRole("button", {name: /Credits/})
  await expect(balance).toBeVisible()
  // The button answers once its live view has connected, as it has for a person
  // by the time they reach for it.
  await expect(page.locator(".phx-connected").filter({has: balance}).first()).toBeAttached()
  await balance.click()
  const dialog = page.getByRole("dialog", {name: "Buy Credits"})
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("status", {name: "USDC in this wallet"})).toHaveText("unavailable")
  await problems.expect()
})
