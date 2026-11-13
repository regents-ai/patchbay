import {expect, test, watch} from "./support/test"

// Search opens in the shared window frame, as in ash-template: its results are
// pages and actions before anything is typed, each with its own picture, and
// it fits the screen at every width.
test("search opens in the shared window frame and opens what is chosen", async ({page, isMobile}) => {
  const problems = watch(page)
  await page.goto("/agents")
  const search = page.locator("#shell-search")
  await expect(page.locator("[data-phx-session].phx-connected:has(#shell-search)")).toBeAttached()

  await page.locator("#shell-search-button").click()
  await expect(search).toBeVisible()
  await expect(search).toHaveClass(/\brg-dialog\b/)
  await expect(page.locator("#shell-search-input")).toBeFocused()

  const pages = search.getByRole("group", {name: /^Pages/})
  await expect(pages.getByRole("option", {name: "Questions"})).toBeVisible()
  await expect(pages.locator(".shell-search__kind[data-kind='page']").first()).toBeVisible()
  await expect(search.locator(".shell-search__kind[data-kind='action']").first()).toBeAttached()

  const box = (await search.boundingBox())!
  expect(box.x).toBeGreaterThanOrEqual(0)
  expect(box.x + box.width).toBeLessThanOrEqual(page.viewportSize()!.width)

  if (isMobile) {
    await search.getByRole("button", {name: "Close"}).click()
  } else {
    await page.keyboard.press("Escape")
  }
  await expect(search).toBeHidden()

  if (!isMobile) {
    await page.keyboard.press("Control+k")
    await expect(search).toBeVisible()
    await page.locator("#shell-search-input").fill("sites")
    // Enter opens a result only once the results for what is typed have arrived.
    await expect(search.locator("#shell-search-results")).toHaveAttribute("data-query", "sites")
    await expect(search.getByRole("option", {name: "Sites"}).first()).toHaveAttribute("aria-selected", "true")
    await page.keyboard.press("Enter")
    await expect(page).toHaveURL(/\/sites$/)
  }
  await problems.expect()
})

// Home searches from the header as every page does (Sean, 13 Nov), and the
// window's "See all questions" opens home's list narrowed to the words.
test("home's header search finds a question and opens home's list for the words", async ({page}) => {
  const problems = watch(page)
  await page.goto("/")
  const search = page.locator("#shell-search")
  await expect(page.locator("[data-phx-session].phx-connected:has(#shell-search)")).toBeAttached()

  const button = page.locator("header.pb-masthead #shell-search-button")
  const box = (await button.boundingBox())!
  expect(box.height).toBeGreaterThanOrEqual(44)
  expect(box.x + box.width).toBeLessThanOrEqual(page.viewportSize()!.width)

  await button.click()
  await expect(search).toBeVisible()
  await page.locator("#shell-search-input").fill("not_signed_in")
  await expect(search.locator("#shell-search-results")).toHaveAttribute("data-query", "not_signed_in")
  await expect(search.getByRole("group", {name: /^Questions/}).getByRole("option").first()).toBeVisible()

  await search.getByRole("link", {name: /See all questions/}).click()
  await expect(page).toHaveURL(/\/\?q=not_signed_in$/)
  await expect(page.locator(".pb-search-summary").first()).toContainText("not_signed_in")
  await expect(page.locator("#pb-results .pb-row").first()).toBeVisible()
  await problems.expect()
})
