import {expect, namer, test, watch} from "./support/test"

// The Public Display Name form on the Account page saves with the page's own
// sign-in: its session cookie and forms token, with no call to the sign-in
// service. The walk's person who saves it has the shared profile their sign-in
// gave them (sign_in.exs). As ash-template's public_name.spec.ts.
test.use(namer)

test("Save keeps the name with the page's own sign-in", async ({page}) => {
  const problems = watch(page)
  const walkName = `Walk ${test.info().project.name}`.padEnd(80, "W")
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const form = page.locator("#account-public-name")
  const name = form.getByRole("textbox", {name: "Public Display Name"})
  const save = form.getByRole("button", {name: "Save"})
  await expect(name).toBeVisible()
  await expect(save).toBeVisible()
  // Where Save sits in the form, and how tall the form is, wherever the page scrolls.
  const place = () => Promise.all([form.boundingBox(), save.boundingBox()])
    .then(([f, b]) => ({x: b!.x - f!.x, y: b!.y - f!.y, height: f!.height}))
  const before = await place()

  await name.fill(walkName)
  const change = page.waitForResponse(response =>
    new URL(response.url()).pathname === "/api/v1/profile" && response.request().method() === "PATCH")
  await save.click()
  expect((await change).status()).toBe(200)
  await expect(form.locator("form")).not.toHaveAttribute("aria-busy")
  await expect(form.getByRole("status")).not.toBeEmpty()
  await expect(name).toHaveValue(walkName)
  // The message sits beside Save without moving it.
  expect(await place()).toEqual(before)
  await problems.expect()
})
