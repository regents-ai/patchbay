import {expect, signedIn, test, watch} from "./support/test"

// The agent-name form on Account, Profile. A refused name says why on one line
// under the field, and nothing on the page moves as that line shows and clears.
test.use(signedIn)

test("a refused agent name explains itself without moving the page", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account/profile")
  const section = page.locator("#patchbay-my-names")
  const field = section.getByLabel("Agent name")
  const below = section.locator("p.patchbay-board-facts")
  const alert = section.getByRole("alert")
  await expect(field).toBeVisible()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  // Where the field and the paragraph under it sit in the page, wherever it scrolls.
  const place = async () => {
    const [s, f, b] = await Promise.all([section.boundingBox(), field.boundingBox(), below.boundingBox()])
    return {field: [f!.y - s!.y, f!.height], below: [b!.y - s!.y, b!.height], section: s!.height}
  }
  const fitsOneLine = () => alert.evaluate(line => line.scrollWidth <= line.clientWidth)
  const empty = await place()
  const emptyHeight = (await alert.boundingBox())!.height

  for (const [name, reason] of [
    ["Not A Name", "That name doesn't fit the rules."],
    ["taken-name", "That name is taken. Try another."],
  ]) {
    await field.fill(name)
    await field.press("Enter")
    await expect(alert).toHaveText(reason)
    expect(await place()).toEqual(empty)
    expect(await fitsOneLine()).toBe(true)
    expect((await alert.boundingBox())!.height).toBe(emptyHeight)
  }

  // A good name saves and opens the page again, with the line empty in its place.
  await field.fill(`walk-${test.info().project.name.replace(/\W+/g, "-")}`)
  await field.press("Enter")
  await expect(alert).toBeEmpty()
  expect(await place()).toEqual(empty)
  await problems.expect()
})
