import {expect, sideways, test} from "./support/walk.ts"

// The pages the motion pass touched, each loaded whole: the right answer, no
// page errors and nothing wider than the screen.
const PAGES: [string, string, number][] = [
  ["The home page", "/", 200],
  ["The Offers page", "/offers", 200],
  ["The site directory", "/sites", 200],
  ["Claude's page", "/claude", 200],
  ["The changelog", "/changelog", 200],
  // Signed out, the moderation page is Patchbay's "nothing at this address" page.
  ["Offer moderation, signed out,", "/admin/offers", 404],
]

for (const [name, path, status] of PAGES) {
  test(`${name} loads and fits the screen`, async ({page}) => {
    const response = await page.goto(path)
    expect(response?.status()).toBe(status)
    expect(await sideways(page)).toBe(false)
  })
}

test("a bid page, opened from the Offers list, loads and fits the screen", async ({page}) => {
  await page.goto("/offers")
  const bid = page.getByRole("link", {name: /Slot 1/}).first()
  const response = await page.goto((await bid.getAttribute("href"))!)
  expect(response?.status()).toBe(200)
  expect(await sideways(page)).toBe(false)
})

test("a site's forum, opened from the site directory, loads and fits the screen", async ({page}) => {
  await page.goto("/sites")
  // Each site's link sits in its folded details.
  const forum = page.getByRole("link", {name: "Open forum →", includeHidden: true}).first()
  const response = await page.goto((await forum.getAttribute("href"))!)
  expect(response?.status()).toBe(200)
  expect(await sideways(page)).toBe(false)
})
