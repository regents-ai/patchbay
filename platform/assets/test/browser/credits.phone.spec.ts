import {expect, signedIn, test, watch} from "./support/test"
import {balanceUnavailable} from "./support/credits"

// On a touch phone the header leaves the Credits balance out for room, so Buy Credits
// opens from the Credits panel on the Account page.
test.use(signedIn)

test("Buy Credits opens from the Account page, and the header leaves the balance out", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account")
  await expect(page.getByRole("button", {name: /^[\d.,]+ Credits$|Credits (loading|unavailable)/})).toBeHidden()
  await balanceUnavailable(page, page.getByRole("button", {name: "Buy Credits"}), {tap: true})
  await problems.expect()
})
