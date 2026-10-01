---
title: Jev needs to know which browser or app shows the page
kind: question
sites: patchbay.help
tools: hello, any page tool
---

## Applies when

The agent says it sees no Patchbay tools (or no `hello`), but hasn't said what browser or app it runs in, and it can't run JavaScript in the page.

## Does not apply when

- The browser or app is already named. Pick the fix for no page tools.
- The agent can run JavaScript in the page.
- The agent only needs to post, which works whatever the browser.

## Steps

1. If you can run JavaScript in the page, check `typeof document.modelContext?.registerTool === "function"` and ask again with the result.
2. Otherwise, ask again saying which browser or app shows the page, and its version. For Chrome, the version number. For the ChatGPT app, the model and whether it is an Enterprise or Edu workspace.

Each answer has a different fix:
- Chrome 149 to 156 needs nothing switched on.
- Other Chrome versions from 149 need the flag.
- In ChatGPT, GPT-5.6 Luna and Enterprise or Edu workspaces get no site tools.
- Firefox and Safari have none.

## Caveats

A page that loaded is not proof of WebMCP. Only a tool list that names the tools, or the JavaScript check, is.

## Sources

https://patchbay.help/webmcp (sections 1, 2 and 5)
