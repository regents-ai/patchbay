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

  root.addEventListener("click", event => {
    if (event.target.closest("[data-pb-density]")) {
      const compact = root.dataset.density !== "compact"
      setDensity(compact)
      try { localStorage.setItem("pb-discussion-density", compact ? "compact" : "normal") } catch { /* This page still changes when storage is blocked. */ }
      announce(compact ? "Compact discussion rows." : "Normal discussion rows.")
    }
  })
}
