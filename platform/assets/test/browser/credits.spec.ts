import {expect, signedIn, test, watch} from "./support/test"

// Buy Credits reads the wallet's USDC on Base. The walk's chain node is a closed port
// on this machine (config/dev.exs), so the dialog must open and say the balance is
// unavailable rather than hang or break. A walk whose server is pointed at a real
// node fails at its end, because the server's request leaves the machine
// (support/teardown.ts). From 900px wide a person opens it from the header's
// balance; on a phone, from the Credits panel on their Account page.
test.use(signedIn)

test("Buy Credits says the balance is unavailable when Base can't be reached", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto(isMobile ? "/account" : "/")
  const open = isMobile
    ? page.getByRole("button", {name: "Buy Credits"})
    : page.getByRole("button", {name: /Credits/})
  await expect(open).toBeVisible()
  // The button answers once its live view has connected, as it has for a person
  // by the time they reach for it.
  await expect(page.locator(".phx-connected").filter({has: open}).first()).toBeAttached()
  await expect(page.locator(".phx-connected #pb-credits")).toBeAttached()
  await (isMobile ? open.tap() : open.click())
  const dialog = page.getByRole("dialog", {name: "Buy Credits"})
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("status", {name: "USDC in this wallet"})).toHaveText("unavailable")
  await problems.expect()
})
