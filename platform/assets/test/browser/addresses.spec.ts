import type {Page} from "@playwright/test"
import {expect, signedIn, test, watch} from "./support/test"

// Every ENS name, full 0x address and short address a page shows is drawn with
// Regent.Primitives.address (.rg-address): its words open the full address and its
// copy icon copies it (founder, 19 Oct 2026). The walk's person, who has no chosen
// name, asked a thread and an agent signing in with its own wallet answered it
// (support/report.exs), so both are shown under their wallets.
//
// Left out, each for a reason a person can read:
// - a code block (pre), which is copied whole;
// - the header's account chip, a button whose words open the account menu, which
//   draws the address itself, as the Regent template does;
// - a post's and reply's author line, which Regent.Discussion draws as words only
//   until design-system gives it an address author.
const outside = "pre, #pb-account-chip, .rg-discussion__author, .rg-discussion__solved-by"

async function bareAddresses(page: Page) {
  return page.evaluate(outside => {
    const address = /0x[0-9a-fA-F]{4}|\b[a-z0-9-]+\.eth\b/i
    const found: string[] = []
    const words = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    for (let node = words.nextNode(); node; node = words.nextNode()) {
      const parent = node.parentElement
      if (!parent || parent.closest(`.rg-address, .visually-hidden, script, style, ${outside}`)) continue
      if (!parent.checkVisibility()) continue
      const match = node.textContent!.match(address)
      if (match) found.push(`${parent.tagName.toLowerCase()}: ${node.textContent!.trim().slice(0, 80)}`)
    }
    return found
  }, outside)
}

async function expectNoBareAddress(page: Page, path: string) {
  const problems = watch(page)
  expect((await page.goto(path))?.status()).toBe(200)
  expect(await bareAddresses(page), `bare addresses on ${path}`).toEqual([])
  await problems.expect()
}

// The thread the walk's person asked, and the profile of the agent that answered.
async function thread(page: Page) {
  await page.goto("/")
  return (await page.getByRole("link", {name: /asks to sign in again/}).first().getAttribute("href"))!
}

for (const path of ["/", "/about", "/agent-setup", "/changelog", "/incidents", "/incidents/emudhra"]) {
  test(`${path} draws every address with its copy icon`, async ({page}) => {
    await expectNoBareAddress(page, path)
  })
}

test("a thread and its authors' profiles draw every address with its copy icon", async ({page}) => {
  const path = await thread(page)
  await expectNoBareAddress(page, path)

  // The person who asked, and the wallet agent that answered, each by their address.
  const profiles = await page.locator("a[href^='/agents/']").evaluateAll(links =>
    [...new Set(links.map(link => link.getAttribute("href")!))],
  )
  expect(profiles.length).toBeGreaterThanOrEqual(2)

  // A heading that is an address is never cut into words for its entrance, which
  // would copy its buttons and ids. Each page is watched frame by frame from its
  // first paint through the entrance.
  await page.addInitScript(() => {
    ;(window as unknown as {copiedIds: Promise<string[]>}).copiedIds = new Promise(resolve => {
      const seen = new Set<string>()
      const until = performance.now() + 1500
      const look = () => {
        const ids = [...document.querySelectorAll("h1 [id]")].map(part => part.id)
        ids.filter((id, at) => ids.indexOf(id) !== at).forEach(id => seen.add(id))
        if (performance.now() < until) requestAnimationFrame(look)
        else resolve([...seen])
      }
      requestAnimationFrame(look)
    })
  })
  for (const profile of profiles) {
    await expectNoBareAddress(page, profile)
    await expect(page.locator("h1 .rg-address")).toHaveCount(1)
    const copied = await page.evaluate(() => (window as unknown as {copiedIds: Promise<string[]>}).copiedIds)
    expect(copied, "ids copied in the heading").toEqual([])
    await expect(page.locator("h1 button")).toHaveCount(2)
  }
})

test.describe("signed in", () => {
  test.use(signedIn)

  for (const path of ["/", "/account/profile", "/credits-help"]) {
    test(`${path} draws every address with its copy icon`, async ({page}) => {
      await expectNoBareAddress(page, path)
    })
  }

  test("the thread's reply form names the reader by their address", async ({page}) => {
    const path = await thread(page)
    await expectNoBareAddress(page, path)
    await expect(page.locator(".pb-reply-as .rg-address")).toHaveCount(1)
  })
})
