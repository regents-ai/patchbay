import assert from "node:assert/strict"
import {test} from "node:test"

import {addressLike, mountSiteCheck, type SiteAnswer, type SiteTool} from "../../js/site_check.ts"

type Fixture = {value?: string; answers?: Record<string, SiteAnswer | "offline">}

function fixture({value = "", answers = {}}: Fixture = {}) {
  const listeners: Record<string, () => void> = {}
  const field = {value, addEventListener: (type: string, fn: () => void) => (listeners[type] = fn)}
  const line: {textContent: string; dataset: DOMStringMap} = {textContent: "", dataset: {}}
  const directory: {hidden: boolean; dataset: DOMStringMap} = {hidden: true, dataset: {}}
  const byId = {"#pb-fix-site-check": line, "#pb-fix-directory": directory}
  const form = {
    elements: {"ask[site_url]": field},
    querySelector: <S extends keyof typeof byId>(selector: S) => byId[selector],
  }
  const asked: string[] = []
  const fetch = async (url: string) => {
    const address = decodeURIComponent(url.split("site_url=")[1])
    asked.push(address)
    const answer = answers[address]
    if (answer === "offline") throw new Error("offline")
    return {json: async () => answer}
  }
  const timers: Array<() => void> = []
  const listed: string[][] = []
  const options = {
    fetch,
    setTimeout: (fn: () => void) => timers.push(fn),
    clearTimeout: () => {},
    onTools: (tools: SiteTool[]) => listed.push(tools.map(tool => tool.name)),
  }
  return {form, field, line, directory, asked, listeners, timers, listed, options}
}

const tools = [{name: "search_docs", description: "Searches the docs."}, {name: "open_page", description: "Opens a page."}]
const found = {status: "found", said: "Patchbay found 2 WebMCP tools here.", tools, directory: false}
const none = {status: "none", said: "Patchbay found no WebMCP tools at this address.", directory: false}

test("an address with tools is said under the field and its tools are listed", async () => {
  const f = fixture({answers: {"https://developers.openai.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)!
  f.field.value = "https://developers.openai.com/"
  await mounted.check()
  assert.equal(f.line.textContent, found.said)
  assert.equal(f.line.dataset.pbCheck, "found")
  assert.deepEqual(f.listed.at(-1), ["search_docs", "open_page"])
})

test("an address without tools is said, and clearing the field clears the line", async () => {
  const f = fixture({answers: {"https://example.com/": none, "https://webmcp.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)!
  f.field.value = "https://example.com/"
  await mounted.check()
  assert.equal(f.line.dataset.pbCheck, "none")

  f.field.value = "https://webmcp.com/"
  await mounted.check()
  assert.equal(f.line.dataset.pbCheck, "found")

  f.field.value = ""
  await mounted.check()
  assert.equal(f.line.textContent, "")
  assert.equal(f.line.dataset.pbCheck, undefined)
})

test("each address is asked about once, however often the field says it", async () => {
  const f = fixture({answers: {"https://example.com/": none}})
  const mounted = mountSiteCheck(f.form, f.options)!
  f.field.value = "https://example.com/"
  await Promise.all([mounted.check(), mounted.check()])
  await mounted.check()
  assert.deepEqual(f.asked, ["https://example.com/"])
})

test("the directory arrives once Patchbay says so, and stays", async () => {
  const second = {...none, directory: true}
  const f = fixture({answers: {"https://a.example.org/": none, "https://b.example.org/": second, "https://webmcp.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)!
  for (const address of ["https://a.example.org/", "https://b.example.org/"]) {
    f.field.value = address
    await mounted.check()
  }
  assert.equal(f.directory.hidden, false)
  assert.equal(f.directory.dataset.pbArrived, "true")

  f.field.value = "https://webmcp.com/"
  await mounted.check()
  assert.equal(f.directory.hidden, false)
})

test("a wait or a failed look is not kept for the address, and a failure says nothing", async () => {
  const limited = {status: "limited", said: "Try again in 40 minutes.", directory: true}
  const f = fixture({answers: {"https://example.com/": limited, "https://down.example.com/": "offline"}})
  const mounted = mountSiteCheck(f.form, f.options)!
  f.field.value = "https://example.com/"
  await mounted.check()
  assert.equal(f.line.dataset.pbCheck, "limited")
  await mounted.check()
  assert.equal(f.asked.length, 2)

  f.field.value = "https://down.example.com/"
  await mounted.check()
  assert.equal(f.line.textContent, "")
})

test("an answer for an address no longer in the field is dropped", async () => {
  const f = fixture({answers: {"https://example.com/": none}})
  const mounted = mountSiteCheck(f.form, f.options)!
  f.field.value = "https://example.com/"
  const pending = mounted.check()
  f.field.value = "https://example.com/app"
  await pending
  assert.equal(f.line.dataset.pbCheck, "checking")
})

test("typing waits for a pause; leaving the field asks at once; a typed-in address is asked on load", async () => {
  const f = fixture({value: "https://developers.openai.com/", answers: {"https://developers.openai.com/": found}})
  mountSiteCheck(f.form, f.options)
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(f.asked, ["https://developers.openai.com/"])

  f.listeners.input()
  assert.equal(f.timers.length, 1)
})

test("only a whole named address is worth asking about", () => {
  assert.equal(addressLike("https://developers.openai.com/"), true)
  assert.equal(addressLike("http://example.com"), true)
  assert.equal(addressLike("https://developers"), false)
  assert.equal(addressLike("https://developers.o"), false)
  assert.equal(addressLike("developers.openai.com"), true)
  assert.equal(addressLike("developers"), false)
  assert.equal(addressLike("ftp://example.com"), false)
})
