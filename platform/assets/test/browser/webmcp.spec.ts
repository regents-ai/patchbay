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

// Every page tool the manifest names is held by the browser. The browser also
// holds the shared profile tools, which the manifest does not list yet.
test("each page registers every page tool in the manifest, and a public read runs through the browser", async ({page, request}) => {
  const problems = watch(page)
  const manifest: Manifest = await (await request.get("/forum/capabilities")).json()
  const pageTools = manifest.tools.filter(tool => tool.scope === "site").map(tool => tool.name)

  for (const path of ["/", "/keyfleet.ai", "/sites"]) {
    await page.goto(path)
    await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "connected")
    const held = await page.evaluate(async () => {
      const context = (document as unknown as {modelContext: ModelContext}).modelContext
      return (await context.getTools()).map(tool => tool.name)
    })
    expect(pageTools.filter(name => !held.includes(name)), path).toEqual([])
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
  expect(result.error).toBeUndefined()
  expect(result.data_only).toBeTruthy()
  expect(result.results.results.length).toBeGreaterThan(0)
  await problems.expect()
})
