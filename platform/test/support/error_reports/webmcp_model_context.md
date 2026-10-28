WebMCP: navigator.modelContext is undefined in Chrome 152+. Use document.modelContext and the WebMCPTesting flag

**Error** (page code written for the early API):

    TypeError: Cannot read properties of undefined (reading 'registerTool')

`navigator.modelContext` and `navigator.modelContextTesting` are gone from Chrome 152.
Chromium removed the testing interface ("WebMCP: Remove the ModelContextTesting API", relanded
8 July 2026) and the navigator name; Mozilla tracks the same removal. The API is
`document.modelContext` with `registerTool`, `getTools` and `executeTool`.
`modelContextTesting.listTools()` is now `document.modelContext.getTools()`.

**Reproduction, 27 Oct 2026, Chrome 156.0.8078.48** (headless, fresh profile, page on
127.0.0.1 so it is a secure context):

| Launch | navigator.modelContext | navigator.modelContextTesting | document.modelContext |
| --- | --- | --- | --- |
| no flag | undefined | undefined | undefined |
| `--enable-features=WebMCPTesting` | undefined | undefined | object: registerTool, getTools, executeTool, ontoolchange, ontoolactivated, ontoolcancel |

With the flag, registering an `echo` tool works and `getTools()` returns `["echo"]`.

**Second trap:** `--enable-blink-features=ModelContext,ModelContextTesting` does not switch it
on. The switch is `chrome://flags/#enable-webmcp-testing` (relaunch the browser), or
`--enable-features=WebMCPTesting` on the command line, or an origin-trial token for your site.

**Fix:**

    if (typeof document.modelContext?.registerTool === "function") {
      await document.modelContext.registerTool({ name, description, inputSchema, execute });
    }

List tools with `await document.modelContext.getTools()`. The `@mcp-b` packages moved to
`document.modelContext` in 6.0.

**If `document.modelContext` is still undefined with the flag on:** the browser you are in may
not pass page tools to agents at all (seen in Grok Bot's browser on Chrome 151 and Edge's
Copilot drawer). That is the host, not your page.

Evidence: WebMCP-org/npm-packages issue 270; sightmap issue 413; GoogleChromeLabs/webmcp-tools
issue 34; Mozilla bugs 2053430 and 2053854.
