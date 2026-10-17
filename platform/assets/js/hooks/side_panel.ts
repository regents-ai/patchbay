// The side panel for a signed-in person on every page, opened by their name in
// the header (PatchbayWeb.SidePanelLive), as in the Regent template's
// shell_panels.ts. Whether it is open lives on <html data-aside>, which the
// server first draws from the cookie written here (PatchbayWeb.Plugs.Panels), so
// LiveView never patches it away. On a phone, where the panel covers the page, it
// opens only when the person opens it on this page (<html data-aside-here>),
// never from the remembered state.

type SidePanelHook = {
  el: HTMLElement
  cleanup?: () => void
}

const yearInSeconds = 60 * 60 * 24 * 365
const root = () => document.documentElement
const covering = window.matchMedia("(max-width: 47.99rem)")

export const asideOpen = () =>
  root().dataset.aside === "open" && (!covering.matches || root().dataset.asideHere !== undefined)

// Closed is the default, so only open is kept.
function remember(open: boolean) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  const age = open ? yearInSeconds : 0
  document.cookie = `patchbay_aside=${open ? "open" : "closed"}; Path=/; Max-Age=${age}; SameSite=Lax${secure}`
}

const syncToggles = () =>
  document.querySelectorAll("[data-aside-toggle]").forEach(toggle =>
    toggle.setAttribute("aria-expanded", String(asideOpen())))

export const SidePanel = {
  mounted(this: SidePanelHook) {
    const aside = this.el
    const chip = () => document.querySelector<HTMLElement>("#pb-account-chip")

    const setAside = (open: boolean) => {
      root().dataset.aside = open ? "open" : "closed"
      if (open) root().dataset.asideHere = ""
      else delete root().dataset.asideHere
      remember(open)
      syncToggles()
      // Opened, focus moves into it, so Escape closes it and returns focus to the
      // name, and what it shows is read again.
      if (!open) return
      // On a phone it hangs under the header, which keeps the name that closes it.
      if (covering.matches) window.scrollTo({top: 0})
      aside.focus({preventScroll: true})
      aside
        .querySelectorAll("[data-read-on-open]")
        .forEach(reader => reader.dispatchEvent(new CustomEvent("pb:aside-opened")))
    }

    // The name in the header toggles it; the Account page's Pair New Agent opens it.
    const onClick = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null
      if (!target) return
      if (target.closest("[data-aside-toggle]")) return setAside(!asideOpen())
      if (target.closest("[data-aside-open]")) return setAside(true)
      // On a phone, where the panel covers the page, a link inside it closes it.
      if (covering.matches && target.closest("#shell-aside a")) setAside(false)
    }

    const onKeydown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && asideOpen() && aside.contains(document.activeElement)) {
        event.preventDefault()
        setAside(false)
        chip()?.focus()
      }
    }

    document.addEventListener("click", onClick)
    document.addEventListener("keydown", onKeydown)
    covering.addEventListener("change", syncToggles)
    syncToggles()

    // A link that names the panel's pairing section, such as /start's Pair New
    // Agent, arrives with it in the address and opens the panel on it.
    if (window.location.hash === "#shell-pairing") setAside(true)

    this.cleanup = () => {
      document.removeEventListener("click", onClick)
      document.removeEventListener("keydown", onKeydown)
      covering.removeEventListener("change", syncToggles)
    }
  },
  destroyed(this: SidePanelHook) {
    this.cleanup?.()
  },
}
