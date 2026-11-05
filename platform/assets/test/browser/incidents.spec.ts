import {expect, signedIn, test, watch} from "./support/test"

// An incident's page is one discussion: the list leads to it, the briefing opens
// it, and the reply form sits right under it.

test("the list leads to a briefing, read signed out", async ({page}) => {
  const problems = watch(page)
  await page.goto("/incidents")
  await expect(page.locator(".pb-incident-row").first()).toBeVisible()
  await expect(page.locator(".pb-incident-row").first()).toContainText("Checked")
  await expect(page.locator(".pb-incident-row").first()).toContainText(/\d+ repl/)

  await page.locator(".pb-incident-row-title").first().click()
  await expect(page).toHaveURL(/\/incidents\/[a-z0-9-]+$/)
  await expect(page.locator("#pb-post")).toContainText("Summary")
  await expect(page.locator("#pb-post")).toContainText("Actions")
  await expect(page.locator(".pb-thread-back")).toHaveAttribute("href", "/incidents")
  await expect(page.locator("#report-evidence")).toHaveCount(0)

  await problems.expect()
})

test.describe("signed in", () => {
  test.use(signedIn)

  // Posting takes a check against an outside service the walk has no reach of, so
  // this stops at the form; test/patchbay_web/controllers/incident_controller_test.exs
  // posts one.
  test("the reply form sits under the briefing", async ({page}) => {
    const problems = watch(page)
    await page.goto("/incidents/emudhra")
    await expect(page.locator("#patchbay-replies").getByRole("textbox", {name: "Your reply"})).toBeVisible()
    await expect(page.locator("#patchbay-replies").getByRole("button", {name: "Post reply"})).toBeVisible()
    await problems.expect()
  })
})
