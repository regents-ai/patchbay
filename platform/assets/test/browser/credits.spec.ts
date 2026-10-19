import {expect, signedIn, test, watch} from "./support/test"

// The Buy Credits dialog reads the wallet's USDC on Base. The walk's chain node is a
// closed port on this machine (config/dev.exs), so the dialog must open and say the
// balance is unavailable rather than hang or break. A walk whose server is pointed
// at a real node fails at its end, because the server's request leaves the machine
// (support/teardown.ts).
test.use(signedIn)

test("Buy Credits says the balance is unavailable when Base can't be reached", async ({page}) => {
  const problems = watch(page)
  await page.goto("/")
  // Every page opens the dialog with this event; on a phone its button sits in a menu.
  await expect(page.locator(".phx-connected #pb-credits")).toBeAttached()
  await page.locator("#pb-credits").dispatchEvent("pb:credits-open")
  const dialog = page.getByRole("dialog", {name: "Buy Credits"})
  await expect(dialog).toBeVisible()
  await expect(dialog.locator(".credits-panel__usdc")).toHaveText("unavailable")
  await problems.expect()
})
