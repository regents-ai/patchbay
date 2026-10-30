import {expect, signedIn, test, watch} from "./support/test"
import {balanceUnavailable} from "./support/credits"

// On a desktop, Buy Credits opens from the account menu's balance on any page and
// from the Credits panel on the Account page.
test.use(signedIn)

test("the account menu's balance opens Buy Credits", async ({page}) => {
  const problems = watch(page)
  await page.goto("/")
  await page.locator("#pb-account-chip").click()
  await balanceUnavailable(page, page.locator("#account-menu-credits"))
  await problems.expect()
})

test("the Account page's Buy Credits opens it too", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account")
  await balanceUnavailable(page, page.getByRole("button", {name: "Buy Credits"}))
  await problems.expect()
})
