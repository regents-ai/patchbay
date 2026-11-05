import {expect, signedIn, test, watch} from "./support/test"

// On an incident's discussion a person likes the briefing and says a reply worked,
// and each press shows on the page they come back to. One width only: the walk's
// person is one person, so two widths at once would press each other's buttons.

test.use(signedIn)

test("a person likes the briefing and says a reply worked", async ({page}) => {
  const problems = watch(page)
  await page.goto("/incidents/emudhra")

  await page.locator("#pb-post form[action$='/likes'] button").click()
  await expect(page).toHaveURL(/\/incidents\/emudhra/)
  await expect(page.locator("#pb-post form[action$='/likes'] input[name=like]")).toHaveValue("false")

  const worked = page.locator("form[action$='/worked'] button").first()
  await expect(worked).toHaveAttribute("aria-pressed", "false")
  await worked.click()
  await expect(page).toHaveURL(/\/incidents\/emudhra/)
  await expect(page.locator("form[action$='/worked'] button").first()).toHaveAttribute("aria-pressed", "true")
  await expect(page.getByText("Worked for 1 other").first()).toBeVisible()

  await problems.expect()
})
