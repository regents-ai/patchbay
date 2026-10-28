import {expect, test} from "./support/motion"
import {watch} from "./support/test"

// The pages the motion pass touched, each loaded whole: the right answer, no
// page errors and nothing wider than the screen.
const PAGES: [string, string, number][] = [
  ["The home page", "/", 200],
  ["The Offers page", "/offers", 200],
  ["The site directory", "/sites", 200],
  ["Claude's page", "/claude", 200],
  ["The agents page", "/agents", 200],
  ["The changelog", "/changelog", 200],
  ["The incidents list", "/incidents", 200],
  ["The eMudhra incident's page", "/incidents/emudhra", 200],
  ["The PHP incident's page", "/incidents/php-cve-2026-109618", 200],
  ["The PingCAP incident's page", "/incidents/pingcap-tidb-cloud", 200],
  // Signed out, the moderation page is Patchbay's "nothing at this address" page.
  ["Offer moderation, signed out,", "/admin/offers", 404],
]

for (const [name, path, status] of PAGES) {
  test(`${name} loads and fits the screen`, async ({page}) => {
    const problems = watch(page)
    const response = await page.goto(path)
    expect(response?.status()).toBe(status)
    await problems.expect()
  })
}

test("a bid page, opened from the Offers list, loads and fits the screen", async ({page}) => {
  await page.goto("/offers")
  const bid = page.getByRole("link", {name: /Slot 1/}).first()
  const problems = watch(page)
  const response = await page.goto((await bid.getAttribute("href"))!)
  expect(response?.status()).toBe(200)
  await problems.expect()
})

test("a site's forum, opened from the site directory, loads and fits the screen", async ({page}) => {
  await page.goto("/sites")
  // Each site's link sits in its folded details.
  const forum = page.getByRole("link", {name: "Open forum →", includeHidden: true}).first()
  const problems = watch(page)
  const response = await page.goto((await forum.getAttribute("href"))!)
  expect(response?.status()).toBe(200)
  await problems.expect()
})

test("the Wallet Bench's open Filter panel sits above the board on a phone", async ({page}, info) => {
  test.skip(info.project.name !== "phone", "checked at 390 wide")
  const problems = watch(page)
  expect((await page.goto("/wallet-bench"))?.status()).toBe(200)
  await page.locator("#pb-wb-filter > summary").click()
  const panel = page.locator("#pb-wb-filter > form")
  await expect(panel).toBeVisible()

  // The board's sticky headings sit under the panel; at its centre the panel is what shows.
  const onTop = await panel.evaluate(form => {
    const box = form.getBoundingClientRect()
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
    return hit !== null && form.contains(hit)
  })
  expect(onTop, "the open Filter panel is topmost at its centre").toBe(true)
  await problems.expect()
})

test("How the bench works keeps its cards in the sheet's colours in dark mode", async ({page}) => {
  await page.emulateMedia({colorScheme: "dark"})
  const problems = watch(page)
  expect((await page.goto("/wallet-bench/how-it-works"))?.status()).toBe(200)
  const background = (selector: string) =>
    page.locator(selector).first().evaluate(element => getComputedStyle(element).backgroundColor)

  expect(await page.locator(".pb-wb-card").count()).toBe(2)
  expect(await background(".pb-wb-card")).toBe(await background(".pb-wb-sheet"))
  await problems.expect()
})

// The walk's one report (support/report.exs) is about the not_signed_in error.
test("a report's page leads its tab title with its error, at an address in its words", async ({page}) => {
  await page.goto("/")
  const address = (await page.getByRole("link", {name: /not_signed_in/}).first().getAttribute("href"))!
  expect(address).toMatch(/^\/posts\/[0-9a-f-]{36}\/regents-keyfleet-not-signed-in-/)

  // The post's id alone moves to the same page.
  const problems = watch(page)
  const response = await page.goto(address.split("/").slice(0, 3).join("/"))
  expect(response?.status()).toBe(200)
  expect(new URL(page.url()).pathname).toBe(address)
  await expect(page).toHaveTitle(/^regents keyfleet: "not_signed_in"/)
  await problems.expect()
})
