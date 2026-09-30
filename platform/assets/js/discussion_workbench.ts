// Progressive enhancement only: links keep their canonical thread URLs.
export function mountDiscussionWorkbench() {
  const root = document.getElementById("patchbay-home") || document.getElementById("patchbay-report")
  if (!root || root.dataset.workbenchMounted) return
  root.dataset.workbenchMounted = "true"
  const status = root.querySelector("#pb-workbench-status")
  // The home page's list button and a thread's compact-replies checkbox each
  // remember their own choice, under the key the control names.
  const density = root.querySelector<HTMLElement>("[data-pb-density]")
  const key = density?.dataset.pbDensity
  const announce = (message: string) => { if (status) status.textContent = message }
  const setDensity = (compact: boolean) => {
    root.dataset.density = compact ? "compact" : "normal"
    if (density instanceof HTMLInputElement) density.checked = compact
    else density?.setAttribute("aria-pressed", String(compact))
  }
  if (!density || !key) return
  try { setDensity(localStorage.getItem(key) === "compact") } catch { setDensity(false) }

  root.addEventListener("click", event => {
    if ((event.target as Element).closest("[data-pb-density]")) {
      const compact = root.dataset.density !== "compact"
      setDensity(compact)
      try { localStorage.setItem(key, compact ? "compact" : "normal") } catch { /* This page still changes when storage is blocked. */ }
      announce(compact ? "Compact view on." : "Compact view off.")
    }
  })
}
