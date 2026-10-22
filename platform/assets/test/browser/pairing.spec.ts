import {expect, signedIn, test, watch} from "./support/test"

// Pairing an agent from the Account page: Pair New Agent opens the side panel's
// pairing box, and choosing an agent gives the message to paste to it.
test.use(signedIn)

test("the pairing message names the Regents Labs account and the site", async ({page}) => {
  const problems = watch(page)
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await page.getByRole("button", {name: "Pair New Agent"}).click()

  const pairing = page.locator("#shell-pairing")
  await expect(pairing).toBeInViewport()
  const radio = pairing.getByRole("radio", {name: "Hermes", exact: true})
  await radio.locator("xpath=ancestor::label").click()
  await expect(radio).toBeChecked()

  const message = page.locator("#shell-pairing-box pre")
  await expect(message).toContainText(/^Pair with my Regents Labs account on localhost\n/)
  await expect(message).toContainText(/Pairing code:\s*\S{12,}/)
  await problems.expect()
})
