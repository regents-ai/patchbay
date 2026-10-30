import {signedIn, test, watch} from "./support/test"
import {balanceUnavailable} from "./support/credits"

// On a touch phone Buy Credits opens from the Credits panel on the Account page too.
// The account menu's balance row is walked in account_menu.spec.ts.
test.use(signedIn)

test("Buy Credits opens from the Account page", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account")
  await balanceUnavailable(page, page.getByRole("button", {name: "Buy Credits"}), {tap: true})
  await problems.expect()
})
