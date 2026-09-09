const root = document.documentElement
const system = matchMedia("(prefers-color-scheme: light)")
function apply(theme) {
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
  const theme = root.dataset.theme === "dark" ? "light" : "dark"
  try { localStorage.setItem("patchbay-theme", theme) } catch {}
  apply(theme)
})
system.addEventListener("change", () => {
  try { if (localStorage.getItem("patchbay-theme")) return } catch {}
  apply(system.matches ? "light" : "dark")
})
window.addEventListener("phx:page-loading-stop", () => apply(root.dataset.theme))
apply(root.dataset.theme)
