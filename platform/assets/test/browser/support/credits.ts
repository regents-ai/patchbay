import {type Locator, type Page} from "@playwright/test"
import {expect} from "./test"

// Buy Credits reads the wallet's USDC on Base. The walk's chain node is a closed port
// on this machine (config/dev.exs), so the dialog must open and say the balance is
// unavailable rather than hang or break. A walk whose server is pointed at a real
// node fails at its end, because the server's request leaves the machine
// (support/teardown.ts).
export async function balanceUnavailable(page: Page, open: Locator, {tap = false} = {}) {
  await expect(open).toBeVisible()
  // The buttons answer once their live views have connected, as they have for a
  // person by the time they reach for one.
  await expect(page.locator(".phx-connected").filter({has: open}).first()).toBeAttached()
  await expect(page.locator(".phx-connected #pb-credits")).toBeAttached()
  await (tap ? open.tap() : open.click())
  const dialog = page.getByRole("dialog", {name: "Buy Credits"})
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("status", {name: "USDC in this wallet"})).toHaveText("unavailable")
}
