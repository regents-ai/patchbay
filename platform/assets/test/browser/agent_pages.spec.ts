import type {Page} from "@playwright/test"
import {expect, test, watch} from "./support/test"

// The agent pages in the site's own look, at 320, 390 and 1280, light and dark.
// Found on 29 Oct (the UI audit, ticket 4): /hermes and the other agent pages drew
// round buttons and fields, started the headline 1px inside the frame, ran the
// crowd of faces past the frame's right edge (436px on a 390 screen), showed two
// Sign in buttons, grew the ask form from 194 to 441px when its field took focus,
// and drew "/hermes/agents.md" in nearly the text's colour with no underline
// (2.15:1). And /agents (ticket 8) drew its agents' names as plain text.

const AGENT_PAGES = ["/hermes", "/claude", "/dots", "/muse", "/grokbot"]
const SCHEMES = ["light", "dark"] as const

// The frame's inner edges, and the page's padding inside them: 24px on a wide
// page, 16px on a phone.
const frameOf = (page: Page) =>
  page.locator(".pb-frame").evaluate(frame => {
    const box = frame.getBoundingClientRect()
    return {left: box.left, right: box.right, padding: innerWidth >= 900 ? 24 : 16}
  })

for (const path of AGENT_PAGES) {
  for (const scheme of SCHEMES) {
    test(`${path} in ${scheme} sits inside the frame with one Sign in and a form that stays still`, async ({page}) => {
      await page.emulateMedia({colorScheme: scheme})
      const problems = watch(page)
      expect((await page.goto(path))?.status()).toBe(200)
      const frame = await frameOf(page)

      // The headline starts the page's padding inside the frame.
      const h1 = (await page.locator("main h1").boundingBox())!
      expect(h1.x - frame.left).toBeGreaterThanOrEqual(frame.padding)

      // Every figure of the crowd stays inside the frame.
      for (const figure of await page.locator(".pb-agent-crowd > *").all()) {
        const box = (await figure.boundingBox())!
        expect(box.x).toBeGreaterThanOrEqual(frame.left)
        expect(box.x + box.width).toBeLessThanOrEqual(frame.right)
      }

      // The header's Sign in is the only one on the page.
      await expect(page.getByRole("button", {name: "Sign in", exact: true}).filter({visible: true})).toHaveCount(1)

      // Buttons and fields keep the site's square corners.
      const corners = await page.locator("main").evaluate(main =>
        [...main.querySelectorAll(".rg-button, input:not([type=radio]):not([type=checkbox]), textarea, summary")]
          .map(element => getComputedStyle(element).borderTopLeftRadius)
          .filter(radius => radius !== "0px"))
      expect(corners).toEqual([])

      // The form is whole from the start: focusing its first field moves nothing.
      const form = page.locator("#pb-hero-form")
      const before = (await form.boundingBox())!.height
      await page.locator("#pb-fix-goal").focus()
      expect((await form.boundingBox())!.height).toBe(before)

      // Links in running text are underlined.
      const plain = await page.locator("main").evaluate(main =>
        [...main.querySelectorAll(".pb-agent-start a, .pb-agent-step p a")]
          .filter(link => !getComputedStyle(link).textDecorationLine.includes("underline"))
          .map(link => link.textContent))
      expect(plain).toEqual([])
      await problems.expect()
    })
  }
}

for (const scheme of SCHEMES) {
  test(`a troubleshooting page in ${scheme} keeps square corners and underlined links`, async ({page}) => {
    await page.emulateMedia({colorScheme: scheme})
    const problems = watch(page)
    expect((await page.goto("/hermes/troubleshooting"))?.status()).toBe(200)
    const frame = await frameOf(page)
    const h1 = (await page.locator("main h1").boundingBox())!
    expect(h1.x - frame.left).toBeGreaterThanOrEqual(frame.padding)

    const found = await page.locator("main").evaluate(main => ({
      round: [...main.querySelectorAll("*")]
        .filter(element => getComputedStyle(element).borderTopLeftRadius !== "0px")
        .map(element => element.outerHTML.slice(0, 80)),
      plain: [...main.querySelectorAll("a:not(.rg-button)")]
        .filter(link => !getComputedStyle(link).textDecorationLine.includes("underline"))
        .map(link => link.textContent),
    }))
    expect(found).toEqual({round: [], plain: []})
    await problems.expect()
  })

  test(`/agents in ${scheme} links every agent with an underline and prints no path`, async ({page}) => {
    await page.emulateMedia({colorScheme: scheme})
    const problems = watch(page)
    expect((await page.goto("/agents"))?.status()).toBe(200)
    const list = page.locator(".pb-agents-list ul > li")
    await expect(list).toHaveCount(11)

    const rows = await list.evaluateAll(items =>
      items.map(item => {
        const link = item.querySelector("a")!
        return {
          underlined: getComputedStyle(link).textDecorationLine.includes("underline"),
          words: item.textContent!.trim(),
        }
      }))
    for (const row of rows) {
      expect(row.underlined, row.words).toBe(true)
      expect(row.words, "no path printed as text").not.toMatch(/(^|\s)\//)
    }
    await problems.expect()
  })
}
