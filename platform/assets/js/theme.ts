// The colour theme switch. Until the visitor chooses, the page carries no theme
// and the shared colours follow the device, dark unless it asks for light. A
// press chooses the opposite of the theme showing, writes it to the cookie the
// server reads so the next page is drawn in it, and restyles this page at once.
// The switch names the theme showing by itself, so nothing here rewrites it.
const root = document.documentElement
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365

type Theme = "light" | "dark"

function chosen(): Theme | undefined {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "light" || value === "dark" ? value : undefined
}

function showing(): Theme {
  const theme = root.dataset.theme
  if (theme === "light" || theme === "dark") return theme
  return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"
}

function apply(theme: Theme) {
  root.dataset.theme = theme
  document.querySelectorAll('meta[name="theme-color"]').forEach(meta => {
    meta.setAttribute("content", theme === "dark" ? "#0F0F10" : "#F6F4EA")
  })
}

document.addEventListener("click", event => {
  if (!(event.target instanceof Element) || !event.target.closest("[data-pb-theme-toggle]")) return
  const theme: Theme = showing() === "dark" ? "light" : "dark"
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${themeCookie}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
  apply(theme)
})

// A page restored from the back-forward cache takes a theme chosen since it was left.
window.addEventListener("pageshow", () => {
  const theme = chosen()
  if (theme) apply(theme)
})

// A module, so its names stay its own.
export {}
