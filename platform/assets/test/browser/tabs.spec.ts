import type {Locator} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// Found on 29 Oct (the UI audit): at 390 the Offers tabs and the Wallet Bench tabs
// wrapped onto two lines, 37px tall, and signed out three of the Offers tabs opened
// sign-in prompts. A tab row stays on one line, scrolling sideways inside itself on
// a phone, every tab at least 44px tall, and signed out Offers shows the two tabs a
// visitor can use.

async function oneLine(row: Locator) {
  const tabs = await row.getByRole("link").all()
  const tops = new Set<number>()
  for (const tab of tabs) {
    const box = (await tab.boundingBox())!
    tops.add(Math.round(box.y))
    expect(box.height).toBeGreaterThanOrEqual(44)
  }
  expect(tops.size, "tab rows on one line").toBe(1)
}

test("signed out, Offers shows Slots and Guide on one line", async ({page}) => {
  const problems = watch(page)
  await page.goto("/offers")
  const row = page.getByRole("navigation", {name: "Agent Offers pages"})
  await expect(row.getByRole("link")).toHaveText(["Slots", "Guide"])
  await oneLine(row)
  await problems.expect()
})

test("the Wallet Bench tabs stay on one line", async ({page}) => {
  const problems = watch(page)
  await page.goto("/wallet-bench")
  const row = page.getByRole("navigation", {name: "Wallet Bench matrices"})
  await expect(row.getByRole("link")).toHaveCount(5)
  await oneLine(row)
  await problems.expect()
})

test.describe("signed in", () => {
  test.use(signedIn)

  test("Offers adds Your Offers, Active and History, still on one line", async ({page}) => {
    const problems = watch(page)
    await page.goto("/offers")
    const row = page.getByRole("navigation", {name: "Agent Offers pages"})
    await expect(row.getByRole("link")).toHaveText(["Slots", "Your Offers", "Active", "History", "Guide"])
    await oneLine(row)
    await problems.expect()
  })
})
