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
  // The developer pages share one column that a long command or table never widens.
  ["The developer docs", "/docs", 200],
  ["The WebMCP guide", "/webmcp", 200],
  ["The privacy page", "/privacy", 200],
  ["Agent payments", "/agent-setup", 200],
  ["The Wallet Bench", "/wallet-bench", 200],
  ["The changelog", "/changelog", 200],
  ["The incidents list", "/incidents", 200],
  ["The eMudhra incident's page", "/incidents/emudhra", 200],
  ["The PHP incident's page", "/incidents/php-cve-2026-109618", 200],
  ["The PingCAP incident's page", "/incidents/pingcap-tidb-cloud", 200],
  ["The Brotli incident's page", "/incidents/brotli-cve-2026-111497", 200],
  ["The Citrix incident's page", "/incidents/citrix-cve-2026-88771", 200],
  ["The Linux incident's page", "/incidents/linux-cve-2026-98432", 200],
  // Signed out, the moderation page is the not-found page.
  ["Offer moderation, signed out,", "/admin/offers", 404],
  // So is a person's admin page, whoever it names.
  ["A person's admin page, signed out,", "/admin/people/agt_nobody", 404],
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

// PB-71: at 320 the category list read "All categ", and long site names lost
// their ends to "…". The list is as wide as its longest category, and every
// name shows whole.
test("the site directory shows its whole category list and every site name", async ({page}) => {
  const problems = watch(page)
  expect((await page.goto("/sites"))?.status()).toBe(200)
  const list = page.locator(".pb-directory-search select")
  const room = await list.evaluate(select => {
    const measure = select.cloneNode(true) as HTMLSelectElement
    measure.style.cssText = "position: absolute; visibility: hidden; width: auto"
    select.parentElement!.append(measure)
    const needed = measure.getBoundingClientRect().width
    measure.remove()
    return {width: select.getBoundingClientRect().width, needed}
  })
  expect(room.width, "the category list fits its longest category").toBeGreaterThanOrEqual(room.needed - 1)
  const cut = await page.locator(".pb-directory-name").evaluateAll(names =>
    names.filter(name => name.scrollWidth > name.clientWidth).map(name => name.textContent))
  expect(cut, "site names cut short").toEqual([])
  await problems.expect()
})

// PB-72: on a wide page an open ask form pushed the board's figures far below
// the sheet above them. The side column's two sheets stay together.
test("the open ask form leaves no gap in the home page's side column", async ({page}, info) => {
  test.skip(info.project.name !== "desktop", "the side column sits beside the posts only on a wide page")
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({contentType: "application/json", body: JSON.stringify({status: "none", said: "", tools: [], directory: false})}))
  const problems = watch(page)
  expect((await page.goto("/"))?.status()).toBe(200)
  await page.locator("#pb-ask > summary").click()
  await page.locator("#pb-hero-details > summary").click()
  await expect(page.getByLabel("Steps")).toBeVisible()
  const gap = await page.evaluate(() =>
    document.querySelector(".pb-home-activity")!.getBoundingClientRect().top -
      document.querySelector(".pb-home-intro")!.getBoundingClientRect().bottom)
  expect(gap, "space between the intro sheet and the figures").toBeLessThanOrEqual(48)
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
test("a report's page leads its tab title and its address with its error", async ({page}) => {
  await page.goto("/")
  const address = (await page.getByRole("link", {name: /not_signed_in/}).first().getAttribute("href"))!
  expect(address).toMatch(/^\/posts\/[0-9a-f-]{36}\/not_signed_in-sign-in-first-regents-auth-login-/)

  // The post's id alone moves to the same page.
  const problems = watch(page)
  const response = await page.goto(address.split("/").slice(0, 3).join("/"))
  expect(response?.status()).toBe(200)
  expect(new URL(page.url()).pathname).toBe(address)
  await expect(page).toHaveTitle(/^not_signed_in: Sign in first: regents auth login --site keyfleet… · Patchbay$/)
  await problems.expect()
})

// Under 768 wide a reference table's rows stand as cards, each value beside its
// column's name; wider, it is a table. Either way it keeps its table roles.
test("the developer docs' table is cards on a phone and a table on a desktop", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto("/docs")
  const table = page.getByRole("table").first()
  const cell = table.getByRole("row").nth(1).getByRole("cell").first()
  await expect(table.getByRole("columnheader")).toHaveCount(3)
  await expect(cell).toHaveText("Site")
  const drawn = await cell.evaluate(element => ({
    display: getComputedStyle(element).display,
    label: getComputedStyle(element, "::before").content,
    fits: element.closest("table")!.scrollWidth <= element.closest("table")!.clientWidth,
  }))
  expect(drawn).toEqual(
    isMobile
      ? {display: "block", label: '"On the form"', fits: true}
      : {display: "table-cell", label: "none", fits: true},
  )
  await problems.expect()
})
