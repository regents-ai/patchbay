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

test("a critical CVE copied from cve.now leads to its post, with the same badges", async ({page}) => {
  const problems = watch(page)
  await page.goto("/incidents")
  const row = page.locator("#patchbay-cves .pb-cve-row").first()
  await expect(row.locator(".pb-cve-id")).toHaveText("CVE-2026-100001")
  await expect(row.locator(".pb-cve-title")).toHaveText("Acme Gateway remote code execution")
  await expect(row.locator(".pb-cve-product")).toHaveText("Acme Gateway")
  const badges = ["CVE", "Critical · 9.8", "Exploited", "Fix available"]
  await expect(row.locator(".pb-cve-badge")).toHaveText(badges)
  await expect(row.locator(".pb-cve-replies")).toHaveText(/^\s*\d+\s+repl/)

  // The row sits within the page at every width, and the whole of it opens the post.
  const box = await row.boundingBox()
  const width = page.viewportSize()?.width ?? 0
  expect(box && box.x >= 0 && box.x + box.width <= width).toBe(true)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)

  await row.locator(".pb-cve-id").click()
  await expect(page).toHaveURL(/\/posts\/[0-9a-f-]+\/cve-2026-100001/)
  await expect(page.locator(".pb-thread .pb-cve-badge")).toHaveText(badges)
  await expect(page.locator("#pb-post")).toContainText("Acme Gateway lets an attacker run code")
  await expect(page.locator("#pb-post").getByRole("link", {name: "cve.now/CVE-2026-100001"})).toHaveAttribute(
    "href",
    "https://cve.now/CVE-2026-100001",
  )

  await problems.expect()
})

for (const [where, path] of [["the home page's Advisories tab", "/?source_kind=advisory"], ["cve.now's board", "/cve.now"]]) {
  test(`${where} gives the CVE the same badges`, async ({page}) => {
    const problems = watch(page)
    await page.goto(path)
    const row = page.locator(".pb-row", {has: page.locator(".pb-row-title", {hasText: "CVE-2026-100001"})})
    await expect(row.locator(".pb-cve-badge")).toHaveText(["CVE", "Critical · 9.8", "Exploited", "Fix available"])
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    await problems.expect()
  })
}

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
