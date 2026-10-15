/** Homepage-only view selection; the existing forum and LiveView keep their own state. */
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
    for (const tab of tabs) {
      const active = tab.dataset.homeView === view
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
      const view = tab.dataset.homeView!
      const url = new URL(window.location.href)
      if (url.searchParams.get("view") !== view) {
        url.searchParams.set("view", view)
        window.history.pushState(null, "", url)
      }
      select(view, event.detail === 0)
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
      select(new URL(window.location.href).searchParams.get("view") === "sites" ? "sites" : "forum", true)
    }
  })
  select(selector.dataset.view || "forum", true)
}
