// Progressive enhancement only: links keep their canonical thread URLs.
export function mountDiscussionWorkbench() {
  const root = document.getElementById("patchbay-home") || document.getElementById("patchbay-report")
  if (!root || root.dataset.workbenchMounted) return
  root.dataset.workbenchMounted = "true"
  const status = root.querySelector("#pb-workbench-status")
  const density = root.querySelector("[data-pb-density]")
  const announce = message => { if (status) status.textContent = message }
  const setDensity = compact => {
    root.dataset.density = compact ? "compact" : "normal"
    density?.setAttribute("aria-pressed", String(compact))
  }
  try { setDensity(localStorage.getItem("pb-discussion-density") === "compact") } catch { setDensity(false) }

  if (root.id === "patchbay-home" && new URL(location.href).searchParams.has("thread") && window.matchMedia("(min-width: 900px)").matches) {
    const title = root.querySelector("#pb-thread-title")
    if (title) { title.tabIndex = -1; title.focus({preventScroll: true}) }
  }

  root.addEventListener("click", event => {
    const thread = event.target.closest("a[data-pb-thread]")
    if (thread && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey && event.button === 0 && window.matchMedia("(min-width: 900px)").matches) {
      event.preventDefault()
      window.location.assign(thread.dataset.pbThread)
      return
    }
    if (event.target.closest("[data-pb-density]")) {
      const compact = root.dataset.density !== "compact"
      setDensity(compact)
      try { localStorage.setItem("pb-discussion-density", compact ? "compact" : "normal") } catch { /* This page still changes when storage is blocked. */ }
      announce(compact ? "Compact discussion rows." : "Normal discussion rows.")
    }
    if (event.target.closest("[data-pb-ask]")) {
      event.preventDefault()
      const help = root.querySelector("#pb-ask")
      if (help) {
        help.scrollIntoView({block: "start"})
        help.querySelector("h2")?.focus({preventScroll: true})
      }
    }
  })
}
