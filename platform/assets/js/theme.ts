// The colour theme travels in a cookie so the server renders it before the
// first paint. The switch writes the cookie and restyles the page at once.
const root = document.documentElement
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365

type Theme = "light" | "dark"

function savedTheme(): Theme {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "dark" ? "dark" : "light"
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

// A page restored from the back-forward cache keeps the theme it was left in.
window.addEventListener("pageshow", () => apply(savedTheme()))
window.addEventListener("phx:page-loading-stop", () => apply(savedTheme()))
apply(savedTheme())

// A module, so its names stay its own.
export {}
