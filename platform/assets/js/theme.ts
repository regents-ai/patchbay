// The colour theme. A theme the visitor chose travels in a cookie so the server
// renders it before the first paint, and it always wins. Without one the page
// follows the device: light when the device asks for light, dark otherwise.
// Every page loads this in its head, before the body is drawn, so a device that
// asks for light never sees the dark page first.
const root = document.documentElement
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365
const deviceLight = window.matchMedia("(prefers-color-scheme: light)")

type Theme = "light" | "dark"

function chosenTheme(): Theme | undefined {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "light" || value === "dark" ? value : undefined
}

function currentTheme(): Theme {
  return chosenTheme() ?? (deviceLight.matches ? "light" : "dark")
}

function apply(theme: Theme) {
  root.dataset.theme = theme
  document.querySelectorAll("[data-pb-theme-toggle]").forEach(button => {
    const current = theme === "dark" ? "Dark" : "Light"
    const next = theme === "dark" ? "Light" : "Dark"
    button.setAttribute("aria-label", `Color theme: ${current}. Activate ${next} theme.`)
    button.setAttribute("aria-pressed", String(theme === "light"))
    button.setAttribute("title", `Switch to ${next}`)
    const state = button.querySelector("[data-theme-toggle-state]")
    if (state) state.textContent = `${current} theme active`
  })
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", theme === "dark" ? "#0F0F10" : "#F6F4EA")
}

document.addEventListener("click", event => {
  if (!(event.target instanceof Element) || !event.target.closest("[data-pb-theme-toggle]")) return
  const theme: Theme = root.dataset.theme === "dark" ? "light" : "dark"
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${themeCookie}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
  apply(theme)
})

// The switch is drawn after this runs, so it takes the theme once the page is
// read. A page restored from the back-forward cache keeps the theme it was left
// in, and a device that changes its setting restyles a page nobody chose for.
document.addEventListener("DOMContentLoaded", () => apply(currentTheme()))
window.addEventListener("pageshow", () => apply(currentTheme()))
window.addEventListener("phx:page-loading-stop", () => apply(currentTheme()))
deviceLight.addEventListener("change", () => apply(currentTheme()))
apply(currentTheme())

// A module, so its names stay its own.
export {}
