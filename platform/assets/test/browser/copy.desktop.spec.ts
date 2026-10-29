import type {Page} from "@playwright/test"
import {expect, signedIn, test} from "./support/test"

// Patchbay's own words never open a heading, label, tab, link, button, table head,
// summary, page title or description with who, what, where, why or when; that reads
// as AI writing (founder, 28 Oct 2026). Headings, labels, legends and tabs are one or
// two words. Run at 1280 over every fixed page the sitemap lists, one site, one tool
// and one thread, and the signed-in pages. Writing by strangers and by the blog's
// authors is theirs: a post's or reply's words, a thread's title and an article.
//
// Left out until their owners change them, each named in the hand-off:
// - /privacy and /terms, which are versioned and change only on Sean's go;
// - /webmcp and the developer page's Hosted MCP section, which the agent-tools
//   branch is rewriting;
// - the blog's index heading, which design-system draws for every Regent site.
// An incident's title and a changelog entry's are their articles' titles, as written.
const skippedPages = ["/privacy", "/terms", "/webmcp"]
const content =
  ".rg-discussion__body, .rg-discussion__title, .rg-blog, .pb-incident-head h1, .pb-changelog__release, #mcp"

const wWord = /^\s*(who|what|where|why|when)\b/i

async function copyProblems(page: Page) {
  return page.evaluate(
    ({content, wWord}) => {
      const opening = new RegExp(wWord, "i")
      const problems: string[] = []
      const words = (element: Element) => {
        const copy = element.cloneNode(true) as Element
        copy.querySelectorAll("[aria-hidden=true], select, .visually-hidden:not(label)").forEach(part => part.remove())
        return (copy.textContent ?? "").replace(/\s+/g, " ").replace(/\s*\(?\d[\d/,]*\)?\s*$/, "").trim()
      }

      const elements = "h1, h2, h3, h4, h5, h6, label, legend, summary, th, caption, dt, button, a, [role=tab]"
      for (const element of document.querySelectorAll(elements)) {
        if (element.closest(content)) continue
        const text = words(element)
        if (!text) continue
        if (opening.test(text)) problems.push(`${element.tagName.toLowerCase()} opens "${text.slice(0, 60)}"`)
        const named = element.matches("h1, h2, h3, h4, h5, h6, label, legend, [role=tab]")
        if (named && text.split(" ").length > 2) problems.push(`${element.tagName.toLowerCase()} "${text.slice(0, 60)}" is over two words`)
      }
      for (const element of document.querySelectorAll("[aria-label], [title], [placeholder]")) {
        if (element.closest(content)) continue
        for (const name of ["aria-label", "title", "placeholder"]) {
          const value = element.getAttribute(name)
          if (value && opening.test(value)) problems.push(`${name} opens "${value.slice(0, 60)}"`)
        }
      }
      const description = document.querySelector<HTMLMetaElement>("meta[name=description]")?.content ?? ""
      for (const [name, value] of [["title", document.title], ["description", description]])
        if (opening.test(value)) problems.push(`page ${name} opens "${value.slice(0, 60)}"`)
      return problems
    },
    {content, wWord: wWord.source},
  )
}

// Every page is read before the check fails, so one run names every problem.
async function expectPlainCopy(page: Page, paths: string[]) {
  const problems: string[] = []
  for (const path of paths) {
    expect((await page.goto(path))?.status(), path).toBe(200)
    for (const problem of await copyProblems(page)) problems.push(`${path}: ${problem}`)
  }
  expect(problems).toEqual([])
}

test("every fixed page, a site, a tool and a thread name things plainly", async ({page}) => {
  test.setTimeout(180_000)
  const sitemap = await (await page.request.get("/sitemap.xml")).text()
  const listed = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => new URL(match[1]).pathname)
  const site = listed.find(path => /^\/[a-z0-9-]+\.[a-z.]+$/.test(path))!
  const tool = listed.find(path => path.includes("/tools/"))!
  const thread = listed.find(path => path.startsWith("/posts/"))!
  const fixed = listed.filter(
    path => !/^\/(posts|blog\/|wallet-bench\/H)/.test(path) && !path.includes(".") && !skippedPages.includes(path),
  )
  expect(fixed.length).toBeGreaterThan(20)

  await expectPlainCopy(page, [...fixed, site, tool, thread, "/blog"])
})

test.describe("signed in", () => {
  test.use(signedIn)

  test("the account and Offers pages name things plainly", async ({page}) => {
    await expectPlainCopy(page, [
      "/account/inbox",
      "/account/profile",
      "/points",
      "/credits-help",
      "/offers/create",
      "/offers/active",
      "/offers/history",
    ])
  })
})
