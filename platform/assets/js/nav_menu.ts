// The phone header's Menu (PatchbayWeb.Forum.BoardHTML.site_nav): the places to go
// and Ask, in a modal window, as in the Regent template's phone header. Opened
// modally, the page behind it is out of reach (inert) until it closes, and Escape
// closes it with focus back on Menu; both are the browser's own. A press on the
// shade beside it closes it too.
export function installNavMenu() {
  document.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return
    const menu = document.getElementById("pb-nav-menu")
    if (!(menu instanceof HTMLDialogElement)) return
    if (target.closest("#pb-menu-button")) return menu.showModal()
    // A press on the shade lands on the dialog itself.
    if (target === menu) menu.close()
  })
}
