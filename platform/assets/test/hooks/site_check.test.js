import assert from "node:assert/strict"
import {test} from "node:test"

import {addressLike, mountSiteCheck} from "../../js/site_check.js"

function fixture({mode = "free", value = "", answers = {}} = {}) {
  const listeners = {}
  const field = {value, addEventListener: (type, fn) => (listeners[type] = fn)}
  const line = {textContent: "", dataset: {}}
  const submit = {disabled: false}
  const directory = {hidden: true, dataset: {}}
  const byId = {"#pb-fix-site-check": line, "#pb-fix-submit": submit, "#pb-fix-directory": directory}
  const form = {dataset: {pbFixMode: mode}, elements: {"fix[site_url]": field}, querySelector: selector => byId[selector]}
  const asked = []
  const fetch = async url => {
    const address = decodeURIComponent(url.split("site_url=")[1])
    asked.push(address)
    const answer = answers[address]
    if (answer === "offline") throw new Error("offline")
    return {json: async () => answer}
  }
  const timers = []
  const options = {fetch, setTimeout: fn => timers.push(fn), clearTimeout: () => {}}
  return {form, field, line, submit, directory, asked, listeners, timers, options}
}

const found = {status: "found", said: "Patchbay found 5 WebMCP tools here.", directory: false}
const none = {status: "none", said: "Patchbay found no WebMCP tools at this address.", directory: false}

test("an address with tools is said under the field and the button stays pressable", async () => {
  const f = fixture({answers: {"https://developers.openai.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)
  f.field.value = "https://developers.openai.com/"
  await mounted.check()
  assert.equal(f.line.textContent, found.said)
  assert.equal(f.line.dataset.pbCheck, "found")
  assert.equal(f.submit.disabled, false)
})

test("an address without tools locks the button until another address is typed", async () => {
  const f = fixture({answers: {"https://example.com/": none, "https://webmcp.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)
  f.field.value = "https://example.com/"
  await mounted.check()
  assert.equal(f.submit.disabled, true)
  assert.equal(f.line.dataset.pbCheck, "none")

  f.field.value = "https://webmcp.com/"
  await mounted.check()
  assert.equal(f.submit.disabled, false)

  f.field.value = ""
  await mounted.check()
  assert.equal(f.line.textContent, "")
  assert.equal(f.line.dataset.pbCheck, undefined)
})

test("each address is asked about once, however often the field says it", async () => {
  const f = fixture({answers: {"https://example.com/": none}})
  const mounted = mountSiteCheck(f.form, f.options)
  f.field.value = "https://example.com/"
  await Promise.all([mounted.check(), mounted.check()])
  await mounted.check()
  assert.deepEqual(f.asked, ["https://example.com/"])
})

test("the directory arrives once Patchbay says so, and stays", async () => {
  const second = {...none, directory: true}
  const f = fixture({answers: {"https://a.example.org/": none, "https://b.example.org/": second, "https://webmcp.com/": found}})
  const mounted = mountSiteCheck(f.form, f.options)
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

test("a wait or a failed look is not kept for the address, and a failure leaves the button alone", async () => {
  const limited = {status: "limited", said: "Try again in 40 minutes.", directory: true}
  const f = fixture({answers: {"https://example.com/": limited, "https://down.example.com/": "offline"}})
  const mounted = mountSiteCheck(f.form, f.options)
  f.field.value = "https://example.com/"
  await mounted.check()
  assert.equal(f.submit.disabled, true)
  await mounted.check()
  assert.equal(f.asked.length, 2)

  f.field.value = "https://down.example.com/"
  await mounted.check()
  assert.equal(f.submit.disabled, false)
  assert.equal(f.line.textContent, "")
})

test("an answer for an address no longer in the field is dropped", async () => {
  const f = fixture({answers: {"https://example.com/": none}})
  const mounted = mountSiteCheck(f.form, f.options)
  f.field.value = "https://example.com/"
  const pending = mounted.check()
  f.field.value = "https://example.com/app"
  await pending
  assert.equal(f.submit.disabled, false)
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

test("a paid fix is never looked at or held back", () => {
  for (const mode of ["pay", "sign_in", "closed"]) {
    const f = fixture({mode, value: "https://example.com/"})
    assert.equal(mountSiteCheck(f.form, f.options), null)
    assert.equal(f.submit.disabled, false)
    assert.deepEqual(f.asked, [])
  }
})

test("only a whole named address is worth asking about", () => {
  assert.equal(addressLike("https://developers.openai.com/"), true)
  assert.equal(addressLike("http://example.com"), true)
  assert.equal(addressLike("https://developers"), false)
  assert.equal(addressLike("https://developers.o"), false)
  assert.equal(addressLike("developers.openai.com"), false)
  assert.equal(addressLike("ftp://example.com"), false)
})
