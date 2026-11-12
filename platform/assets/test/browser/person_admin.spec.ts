import {readFileSync} from "node:fs"
import {expect, test} from "./support/motion"
import {signInFile, watch} from "./support/test"

// A person's admin page (PB-88), as the walk's moderator: it fits the screen,
// Suspend asks before it happens, and the status and the record change on the
// page without a reload, each new row linking to the moderator who made it. Each width has a person of its own, since the widths
// run at once.
test.use({storageState: signInFile("moderator")})

test("a moderator suspends a person after confirming, then reinstates them", async ({page}, info) => {
  const people = JSON.parse(readFileSync(signInFile("admin-people"), "utf8"))
  const problems = watch(page)
  const response = await page.goto(`/admin/people/${people[info.project.name.replace(/\W+/g, "-")]}`)
  expect(response?.status()).toBe(200)
  // The page answers a press once it has connected.
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const status = page.locator("#pb-person-status")
  const history = page.locator("#pb-person-history li")
  await expect(status).toHaveText("Active")
  await problems.expect()

  // Declining the question changes nothing.
  await page.getByLabel("Reason").fill("Spam")
  page.once("dialog", dialog => dialog.dismiss())
  await page.getByRole("button", {name: "Suspend"}).click()
  await expect(status).toHaveText("Active")
  const before = await history.count()

  page.once("dialog", dialog => dialog.accept())
  await page.getByRole("button", {name: "Suspend"}).click()
  await expect(status).toHaveText("Suspended")
  await expect(history).toHaveCount(before + 1)
  await expect(history.first()).toContainText("Spam")
  await expect(history.first().getByRole("link")).toHaveAttribute("href", /^\/agents\/agt_/)
  await problems.expect()

  await page.getByLabel("Reason").fill("Appeal upheld")
  await page.getByRole("button", {name: "Reinstate"}).click()
  await expect(status).toHaveText("Active")
  await expect(history).toHaveCount(before + 2)
  await expect(history.first().getByRole("link")).toHaveAttribute("href", /^\/agents\/agt_/)
  await problems.expect()
})
