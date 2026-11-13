import {expect, signedIn, test, watch} from "./support/test"

// An incident's page is one discussion: the list leads to it, the briefing opens
// it, and the reply form sits right under it.

test("the list leads to a briefing, read signed out", async ({page}) => {
  const problems = watch(page)
  await page.goto("/incidents")
  // The critical CVEs come first, the briefings under them.
  await expect(page.locator("#patchbay-incidents > section").first()).toHaveAttribute("id", "patchbay-cves")
  const briefing = page.locator("#patchbay-briefings .pb-incident-row").first()
  await expect(briefing).toBeVisible()
  await expect(briefing).toContainText("Checked")
  await expect(briefing).toContainText(/\d+ repl/)

  await briefing.locator(".pb-incident-row-title").click()
  await expect(page).toHaveURL(/\/incidents\/[a-z0-9-]+$/)
  await expect(page.locator("#pb-post")).toContainText("Summary")
  await expect(page.locator("#pb-post")).toContainText("Actions")
  await expect(page.locator(".pb-thread-back")).toHaveAttribute("href", "/incidents")
  await expect(page.locator("#report-evidence")).toHaveCount(0)

  await problems.expect()
})

test("a critical CVE copied from cve.now leads to its post", async ({page}) => {
  const problems = watch(page)
  await page.goto("/incidents")
  const row = page.locator("#patchbay-cves .pb-incident-row").first()
  await expect(row).toContainText("CVE-2026-100001")
  await expect(row).toContainText(/\d+ repl/)

  await row.locator(".pb-incident-row-title").click()
  await expect(page).toHaveURL(/\/posts\/[0-9a-f-]+\/cve-2026-100001/)
  await expect(page.locator("#pb-post")).toContainText("Acme Gateway lets an attacker run code")
  await expect(page.locator("#pb-post").getByRole("link", {name: "cve.now/CVE-2026-100001"})).toHaveAttribute(
    "href",
    "https://cve.now/CVE-2026-100001",
  )

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
