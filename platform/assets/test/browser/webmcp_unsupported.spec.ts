import {expect, test, watch} from "./support/test"

// A browser with no WebMCP, as every other walk spec runs: the page registers
// nothing, says so in <html data-webmcp-status>, and still works by hand.
test("without WebMCP the page says so and registers nothing", async ({page}) => {
  const problems = watch(page)
  await page.goto("/")
  await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "unsupported")
  expect(await page.evaluate(() => "modelContext" in document)).toBe(false)
  await problems.expect()
})
