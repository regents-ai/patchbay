const root = document.documentElement
const system = matchMedia("(prefers-color-scheme: light)")
function apply(theme) {
  root.dataset.theme = theme
  document.querySelectorAll("[data-pb-theme-toggle]").forEach(button => {
    button.textContent = theme === "dark" ? "Light" : "Dark"
    button.setAttribute("aria-label", `Switch to ${button.textContent.toLowerCase()} mode`)
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
