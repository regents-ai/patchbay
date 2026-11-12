import {expect, test} from "./support/motion"
import {signInFile, watch} from "./support/test"

// The people list, as the walk's moderator: it fits the screen, the search runs
// on Enter and when the box is left, never while typing, the tick keeps only
// the suspended, a row opens that person's page, and the links above the
// heading lead to the other admin pages. On a touch phone each press is 44 px tall.
test.use({storageState: signInFile("moderator")})

test("a moderator finds a person in the list and opens their page", async ({page, isMobile}) => {
  const problems = watch(page)
  const response = await page.goto("/admin/people")
  expect(response?.status()).toBe(200)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const rows = page.locator("#pb-people > li")
  const everyone = await rows.count()
  expect(everyone).toBeGreaterThan(3)
  await problems.expect()

  if (isMobile) {
    const presses = [
      page.getByLabel("Find"),
      page.locator(".pb-people-only"),
      rows.first().getByRole("link"),
      page.getByRole("navigation", {name: "Admin"}).getByRole("link", {name: "Messages"}),
    ]
    const heights = []
    for (const press of presses) heights.push(Math.round((await press.boundingBox())!.height))
    expect(Math.min(...heights), `press heights ${heights}`).toBeGreaterThanOrEqual(44)
  }

  // Typing alone narrows nothing; leaving the box does.
  const search = page.getByLabel("Find")
  await search.pressSequentially("taken-na")
  await expect(rows).toHaveCount(everyone)
  await search.blur()
  await expect(rows).toHaveCount(1)
  await expect(page).toHaveURL(/\/admin\/people\?q=taken-na$/)

  // So does Enter, here on the start of a wallet address.
  await search.fill("0xcccc")
  await search.press("Enter")
  await expect(rows).toHaveCount(1)
  await expect(rows.first().locator("[data-status]")).toHaveText("Active")
  await problems.expect()

  await search.fill("nobody-by-this-name")
  await search.press("Enter")
  await expect(page.locator("#pb-people-admin .rg-empty")).toBeVisible()
  await problems.expect()

  // The tick keeps only suspended people, however many there are right now.
  await search.fill("")
  await search.press("Enter")
  await expect(rows).toHaveCount(everyone)
  await page.getByLabel("Suspended").check()
  await expect(page).toHaveURL(/\/admin\/people\?suspended=true$/)
  await expect(rows.locator("[data-status=active]")).toHaveCount(0)
  await page.getByLabel("Suspended").uncheck()
  await expect(rows).toHaveCount(everyone)

  await search.fill("0xcccc")
  await search.press("Enter")
  await rows.first().getByRole("link").click()
  await expect(page).toHaveURL(/\/admin\/people\/agt_[0-9a-f]+$/)
  await expect(page.locator("#pb-person-status")).toHaveText("Active")
  await problems.expect()

  const admin = page.getByRole("navigation", {name: "Admin"})
  await admin.getByRole("link", {name: "Messages"}).click()
  await expect(page).toHaveURL(/\/admin\/messages$/)
  await problems.expect()
  await page.getByRole("navigation", {name: "Admin"}).getByRole("link", {name: "People"}).click()
  await expect(page).toHaveURL(/\/admin\/people$/)
  await expect(page.locator("#pb-people > li").first()).toBeVisible()
  await problems.expect()
})
