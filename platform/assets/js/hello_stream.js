// Public names remain text nodes. Stream reads never create greetings.
export function mountHelloStream() {
  const root = document.getElementById("pb-hello-log")
  if (!root) return
  const list = root.querySelector("ol")
  const status = root.querySelector(".pb-hello-status")
  let generation = 0
  let controller
  let timer

  const stop = () => { generation++; clearTimeout(timer); controller?.abort() }
  const refresh = async () => {
    stop()
    if (document.hidden || !root.isConnected) return
    const current = generation
    controller = new AbortController()
    try {
      const response = await fetch(`/hello?stream=${root.dataset.stream === "siwa" ? "siwa" : "all"}`, {
        headers: {accept: "application/json"}, signal: controller.signal, cache: "no-store",
      })
      if (!response.ok) throw new Error("unavailable")
      const body = await response.json()
      if (!Array.isArray(body.events)) throw new Error("invalid stream")
      if (current !== generation) return
      const rows = body.events.map(event => {
        const li = document.createElement("li")
        li.dataset.helloId = event.id
        const name = document.createElement("bdi")
        name.textContent = event.name
        name.title = event.name
        name.className = `pb-hello-name pb-hello-color-${Number.isInteger(event.color) && event.color >= 0 && event.color < 8 ? event.color : 0}${event.verified === true ? " is-siwa" : ""}`
        const greeting = document.createElement("span")
        greeting.lang = event.language
        greeting.textContent = event.greeting
        const sentence = document.createElement("span")
        sentence.append("Agent ", name, " says ", greeting)
        li.append(sentence)
        return li
      })
      list.replaceChildren(...rows)
      status.textContent = rows.length ? "" : root.dataset.stream === "siwa" ? "No SIWA-verified hellos yet." : "No agents have said hello yet."
    } catch (error) {
      if (current === generation && error.name !== "AbortError") status.textContent = list.children.length ? "Hello stream unavailable. Showing the last received greetings." : "Hello stream unavailable."
    } finally {
      if (current === generation && !document.hidden) timer = setTimeout(refresh, 15000)
    }
  }
  root.addEventListener("click", event => {
    const tab = event.target.closest("[data-pb-hello-filter]")
    if (!tab || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
    event.preventDefault()
    root.dataset.stream = tab.dataset.pbHelloFilter
    list.replaceChildren()
    for (const link of root.querySelectorAll("[data-pb-hello-filter]")) {
      if (link === tab) link.setAttribute("aria-current", "true")
      else link.removeAttribute("aria-current")
    }
    status.textContent = "Loading greetings…"
    refresh()
  })
  document.addEventListener("visibilitychange", () => document.hidden ? stop() : refresh())
  window.addEventListener("pagehide", stop)
  window.addEventListener("pageshow", refresh)
  window.addEventListener("patchbay:hello", refresh)
  refresh()
}
