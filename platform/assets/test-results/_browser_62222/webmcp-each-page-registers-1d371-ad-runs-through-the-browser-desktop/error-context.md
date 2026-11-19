# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: webmcp.spec.ts >> each page registers exactly the manifest's page tools, and a public read runs through the browser
- Location: test/browser/webmcp.spec.ts:20:1

# Error details

```
Error: expect(locator).toHaveAttribute(expected) failed

Locator:  locator('html')
Expected: "connected"
Received: "unsupported"
Timeout:  5000ms

Call log:
  - Expect "toHaveAttribute" locator('html') with timeout 5000ms
  - waiting for locator('html')
    14 × locator resolved to <html lang="en" data-phx-loc="3" data-brand="patchbay" data-webmcp-status="unsupported">…</html>
       - unexpected value "unsupported"

```

```yaml
- document:
  - link "Skip to the main content":
    - /url: "#pb-content"
  - banner
  - main
  - complementary "Bids"
  - contentinfo
```

# Test source

```ts
  1  | import {expect, test, watch} from "./support/test"
  2  | 
  3  | // The page's WebMCP tools, as the browser itself holds them. Chromium offers
  4  | // document.modelContext to this local server only with its WebMCP testing
  5  | // switch (chrome://flags/#enable-webmcp-testing); on patchbay.help the
  6  | // origin-trial token does it instead, and that token names patchbay.help alone.
  7  | 
  8  | type Tool = {name: string}
  9  | type ModelContext = {
  10 |   getTools(): Promise<Tool[]>
  11 |   executeTool(tool: Tool, input: unknown): Promise<unknown>
  12 | }
  13 | type Manifest = {tools: {name: string; scope: string}[]}
  14 | 
  15 | test.use({launchOptions: {args: ["--enable-features=WebMCPTesting"]}})
  16 | 
  17 | // The browser holds exactly the page tools the manifest names, no more: none acts
  18 | // with the person's own sign-in (the shared profile tools are not registered), so
  19 | // <html> has no data-profile-webmcp.
  20 | test("each page registers exactly the manifest's page tools, and a public read runs through the browser", async ({page, request}) => {
  21 |   const problems = watch(page)
  22 |   const manifest: Manifest = await (await request.get("/forum/capabilities")).json()
  23 |   const pageTools = manifest.tools.filter(tool => tool.scope === "site").map(tool => tool.name).sort()
  24 | 
  25 |   for (const path of ["/", "/keyfleet.ai", "/sites"]) {
  26 |     await page.goto(path)
> 27 |     await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "connected")
     |                                        ^ Error: expect(locator).toHaveAttribute(expected) failed
  28 |     const held = await page.evaluate(async () => {
  29 |       const context = (document as unknown as {modelContext: ModelContext}).modelContext
  30 |       return (await context.getTools()).map(tool => tool.name)
  31 |     })
  32 |     expect(held.sort(), path).toEqual(pageTools)
  33 |     await expect(page.locator("html"), path).not.toHaveAttribute("data-profile-webmcp")
  34 |   }
  35 | 
  36 |   // search_threads, run by the browser's own WebMCP: the walk's one thread,
  37 |   // asked on keyfleet.ai's board, comes back as quoted data.
  38 |   const answer = await page.evaluate(async () => {
  39 |     const context = (document as unknown as {modelContext: ModelContext}).modelContext
  40 |     const tool = (await context.getTools()).find(entry => entry.name === "search_threads")!
  41 |     const result = await context.executeTool(tool, {origin: "keyfleet.ai"})
  42 |     return typeof result === "string" ? result : JSON.stringify(result)
  43 |   })
  44 |   const result = JSON.parse(answer)
  45 |   expect(result.ok).toBe(true)
  46 |   expect(result.status).toBe(200)
  47 |   expect(result.data.data_only).toBeTruthy()
  48 |   expect(result.data.results.results.length).toBeGreaterThan(0)
  49 |   await problems.expect()
  50 | })
  51 | 
```