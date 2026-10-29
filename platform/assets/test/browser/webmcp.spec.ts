import {expect, test, watch} from "./support/test"

// The page's WebMCP tools, as the browser itself holds them. Chromium offers
// document.modelContext to this local server only with its WebMCP testing
// switch (chrome://flags/#enable-webmcp-testing); on patchbay.help the
// origin-trial token does it instead, and that token names patchbay.help alone.

type Tool = {name: string}
type ModelContext = {
  getTools(): Promise<Tool[]>
  executeTool(tool: Tool, input: unknown): Promise<unknown>
}
type Manifest = {tools: {name: string; scope: string}[]}

test.use({launchOptions: {args: ["--enable-features=WebMCPTesting"]}})

// The browser holds exactly the page tools the manifest names, no more: none acts
// with the person's own sign-in (the shared profile tools are not registered), so
// <html> has no data-profile-webmcp.
test("each page registers exactly the manifest's page tools, and a public read runs through the browser", async ({page, request}) => {
  const problems = watch(page)
  const manifest: Manifest = await (await request.get("/forum/capabilities")).json()
  const pageTools = manifest.tools.filter(tool => tool.scope === "site").map(tool => tool.name).sort()

  for (const path of ["/", "/keyfleet.ai", "/sites"]) {
    await page.goto(path)
    await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "connected")
    const held = await page.evaluate(async () => {
      const context = (document as unknown as {modelContext: ModelContext}).modelContext
      return (await context.getTools()).map(tool => tool.name)
    })
    expect(held.sort(), path).toEqual(pageTools)
    await expect(page.locator("html"), path).not.toHaveAttribute("data-profile-webmcp")
  }

  // search_threads, run by the browser's own WebMCP: the walk's one thread,
  // asked on keyfleet.ai's board, comes back as quoted data.
  const answer = await page.evaluate(async () => {
    const context = (document as unknown as {modelContext: ModelContext}).modelContext
    const tool = (await context.getTools()).find(entry => entry.name === "search_threads")!
    const result = await context.executeTool(tool, {origin: "keyfleet.ai"})
    return typeof result === "string" ? result : JSON.stringify(result)
  })
  const result = JSON.parse(answer)
  expect(result.ok).toBe(true)
  expect(result.status).toBe(200)
  expect(result.data.data_only).toBeTruthy()
  expect(result.data.results.results.length).toBeGreaterThan(0)
  await problems.expect()
})
