import type {Locator} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// The Agent Message button on /agents opens its window at every width: each of
// its three texts fits the screen and copies exactly what it shows, and Escape
// closes it and gives focus back to the button. The walk's person, signed in
// by sign_in.exs, leaves a message from its form and sees the receipt, after a
// reply address that is too long is refused with what they typed kept.
test.use({...signedIn, permissions: ["clipboard-read", "clipboard-write"]})

test("an agent's texts copy, and a signed-in person leaves a message", async ({page, hasTouch}) => {
  const press = (target: Locator) => (hasTouch ? target.tap() : target.click())
  const problems = watch(page)
  await page.goto("/agents")

  const open = page.getByRole("button", {name: "Agent Message"})
  const dialog = page.getByRole("dialog", {name: "Agent Message"})
  await expect(dialog).toBeHidden()
  await press(open)
  await expect(dialog).toBeVisible()

  const texts = dialog.locator(".pb-agent-message-texts > li")
  await expect(texts).toHaveCount(3)
  for (const text of await texts.all()) {
    const code = text.locator("pre")
    expect(await code.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
  }

  const cli = texts.first()
  // By its place, not its name: the button says Copied once it has.
  const copy = cli.locator("button.rg-copy")
  await press(copy)
  await expect(copy).toHaveAttribute("data-copy-state", "copied")
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(copied).toBe(await cli.locator("code").textContent())
  expect(copied).toContain("regents patchbay messages leave agents")

  await page.keyboard.press("Escape")
  await expect(dialog).toBeHidden()
  await expect(open).toBeFocused()
  await press(open)
  await expect(dialog).toBeVisible()

  const form = dialog.locator("#pb-agent-message-person-form")
  await expect(page.locator(".phx-connected:has(#pb-agent-message-person-form)").first()).toBeAttached()
  const body = form.getByRole("textbox", {name: "Message", exact: true})
  const replyTo = form.getByRole("textbox", {name: "Reply to"})

  // The page's own length limit is lifted for one send, so the site's refusal shows.
  await body.fill("The list misses my agent.")
  await replyTo.evaluate(el => el.removeAttribute("maxlength"))
  await replyTo.fill("a".repeat(201))
  await press(form.getByRole("button", {name: "Send"}))
  await expect(replyTo).toHaveAttribute("aria-invalid", "true")
  await expect(body).toHaveValue("The list misses my agent.")
  await expect(dialog.locator("#pb-agent-message-person-receipt")).toHaveCount(0)

  await replyTo.fill("walk@example.com")
  await press(form.getByRole("button", {name: "Send"}))
  const receipt = dialog.locator("#pb-agent-message-person-receipt")
  await expect(receipt).toBeVisible()
  await expect(receipt.locator("code")).toHaveText(/^[0-9a-f-]{36}$/)
  await expect(body).toHaveValue("")
  await expect(dialog).toBeVisible()
  await problems.expect()
})
