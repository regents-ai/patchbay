/**
 * The home page's Forum and Sites views: `/` opens on the forum and `/sites` on the
 * directory. The forum and the directory's LiveView keep their own state.
 */
export function mountHomeViews(): void {
  const selector = document.querySelector<HTMLElement>("[data-home-switch]")
  if (!selector || selector.dataset.mounted) return
  selector.dataset.mounted = "true"
  selector.setAttribute("role", "tablist")
  const tabs = [...selector.querySelectorAll<HTMLAnchorElement>("[data-home-view]")]
  const panels = [...document.querySelectorAll<HTMLElement>("[data-home-panel]")]

  const select = (view: string, keyboard = false) => {
    selector.toggleAttribute("data-keyboard", keyboard)
    selector.dataset.view = view
    const suffix = document.querySelector<HTMLElement>("title")?.dataset.suffix ?? ""
    for (const tab of tabs) {
      const active = tab.dataset.homeView === view
      if (active) document.title = `${tab.textContent?.trim()}${suffix}`
      tab.setAttribute("role", "tab")
      tab.setAttribute("aria-controls", `home-${tab.dataset.homeView}`)
      tab.setAttribute("aria-selected", String(active))
      tab.removeAttribute("aria-current")
      tab.tabIndex = active ? 0 : -1
    }
    for (const panel of panels) {
      panel.hidden = panel.dataset.homePanel !== view
      panel.setAttribute("role", "tabpanel")
    }
  }

  for (const tab of tabs) {
    tab.addEventListener("click", event => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
      event.preventDefault()
      if (new URL(tab.href).pathname !== window.location.pathname) window.history.pushState(null, "", tab.href)
      select(tab.dataset.homeView!, event.detail === 0)
    })
    tab.addEventListener("keydown", event => {
      const index = tabs.indexOf(tab)
      const next = event.key === "ArrowRight" ? (index + 1) % tabs.length
        : event.key === "ArrowLeft" ? (index + tabs.length - 1) % tabs.length
        : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null
      if (next !== null) {
        event.preventDefault()
        tabs[next].focus()
        tabs[next].click()
      } else if (event.key === " ") {
        event.preventDefault()
        tab.click()
      }
    })
  }
  window.addEventListener("popstate", () => {
    if (selector.isConnected) {
      select(window.location.pathname === "/sites" ? "sites" : "forum", true)
    }
  })
  select(selector.dataset.view || "forum", true)
}
