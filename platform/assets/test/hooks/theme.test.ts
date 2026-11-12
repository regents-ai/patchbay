// Invariant: a theme chosen on any switch is written to the cookie the server
// reads and shown on the page at once; the page reads back only the two themes
// it offers; and every switch hears each change of the theme on screen once,
// whoever made it.
import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, it} from "node:test"
import {chooseTheme, chosenTheme, showingTheme, syncTheme, watchTheme, type Theme} from "../../js/theme.ts"

// The browser's own names, which Node has none of, for the length of each test.
const page = globalThis as Record<string, unknown>

type Listener = () => void

let cookies: Map<string, string>
let written: string[]
let dataset: Record<string, string>
let deviceLight: boolean
let deviceListeners: Set<Listener>
let pageObservers: Set<Listener>
let metas: {name: string; media: string; content: string}[]
let location: {pathname: string; protocol: string}

beforeEach(() => {
  cookies = new Map()
  written = []
  deviceLight = false
  deviceListeners = new Set()
  pageObservers = new Set()
  location = {pathname: "/app", protocol: "http:"}
  metas = [
    {name: "color-scheme", media: "", content: "light dark"},
    {name: "theme-color", media: "(prefers-color-scheme: dark)", content: ""},
    {name: "theme-color", media: "(prefers-color-scheme: light)", content: ""},
  ]
  // The page's own attributes: a change to data-theme reaches every observer, as the browser's would.
  dataset = new Proxy({} as Record<string, string>, {
    set(target, name: string, value: string) {
      const changed = target[name] !== value
      target[name] = value
      if (changed && name === "theme") pageObservers.forEach(observer => observer())
      return true
    },
    deleteProperty(target, name: string) {
      const had = name in target
      delete target[name]
      if (had && name === "theme") pageObservers.forEach(observer => observer())
      return true
    },
  })
  const meta = (name: string) => metas.filter(m => m.name === name).map(m => ({
    get media() { return m.media },
    get content() { return m.content },
    set content(value: string) { m.content = value },
    setAttribute: (_: string, value: string) => void (m.content = value),
  }))
  page.document = ({
    documentElement: {dataset},
    get cookie() {
      return [...cookies].map(([name, value]) => `${name}=${value}`).join("; ")
    },
    set cookie(line: string) {
      written.push(line)
      const [pair] = line.split("; ")
      const [name, value] = pair.split("=")
      cookies.set(name, value)
    },
    querySelector: (selector: string) => meta(selector.includes("color-scheme") ? "color-scheme" : "theme-color")[0] ?? null,
    querySelectorAll: () => meta("theme-color"),
  })
  page.window = ({
    location,
    matchMedia: () => ({
      get matches() { return deviceLight },
      addEventListener: (_: string, listener: Listener) => void deviceListeners.add(listener),
      removeEventListener: (_: string, listener: Listener) => void deviceListeners.delete(listener),
    }),
  })
  page.MutationObserver = (class {
    seen: Listener
    constructor(seen: Listener) { this.seen = seen }
    observe() { pageObservers.add(this.seen) }
    disconnect() { pageObservers.delete(this.seen) }
  })
})

afterEach(() => {
  for (const name of ["document", "window", "MutationObserver"]) delete page[name]
})

describe("choosing a theme", () => {
  it("writes the cookie the server reads and shows the theme at once", () => {
    chooseTheme("light")
    assert.equal(chosenTheme(), "light")
    assert.match(written.at(-1)!, /^regent_theme=light; Path=\/; Max-Age=31536000; SameSite=Lax$/)
    assert.equal(dataset.theme, "light")
    assert.equal(showingTheme(), "light")
    assert.equal(metas[0].content, "light")
    assert.deepEqual(metas.slice(1).map(m => m.content), ["#F6F7FA", "#F6F7FA"])

    chooseTheme("dark")
    assert.equal(chosenTheme(), "dark")
    assert.equal(dataset.theme, "dark")
    assert.deepEqual(metas.slice(1).map(m => m.content), ["#111726", "#111726"])
  })

  it("keeps the cookie to secure connections on a secure page", () => {
    location.protocol = "https:"
    chooseTheme("dark")
    assert.match(written.at(-1)!, /; Secure$/)
  })
})

describe("reading the theme", () => {
  it("accepts only the two themes the page offers", () => {
    for (const value of ["blue", "", "Light", "light;"]) {
      cookies.set("regent_theme", value)
      assert.equal(chosenTheme(), undefined)
    }
    cookies.clear()
    cookies.set("other", "light")
    assert.equal(chosenTheme(), undefined)
  })

  it("follows the device until a theme is chosen, then the choice", () => {
    syncTheme()
    assert.equal(dataset.theme, undefined)
    assert.equal(metas[0].content, "light dark")
    assert.equal(showingTheme(), "dark")
    deviceLight = true
    assert.equal(showingTheme(), "light")
    cookies.set("regent_theme", "dark")
    syncTheme()
    assert.equal(showingTheme(), "dark")
  })
})

describe("watching the theme", () => {
  it("hears each change once, whoever made it, and nothing after it stops", () => {
    const heard: Theme[] = []
    const stop = watchTheme(theme => heard.push(theme))

    chooseTheme("light") // another switch
    chooseTheme("light") // the same theme stated again
    syncTheme() // live navigation restating it
    dataset.theme = "dark" // the server's next page
    delete dataset.theme // nothing chosen: the device decides, still dark
    deviceLight = true
    deviceListeners.forEach(listener => listener()) // the device turns light
    assert.deepEqual(heard, ["light", "dark", "light"])

    stop()
    chooseTheme("dark")
    assert.deepEqual(heard, ["light", "dark", "light"])
    assert.equal(pageObservers.size, 0)
    assert.equal(deviceListeners.size, 0)
  })
})
