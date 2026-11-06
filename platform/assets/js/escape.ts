// Escape, on every page, as in the Regent template's app.ts. An open popover, such
// as the account menu, takes Escape itself, and so does an open dropdown
// (pill_select.mjs). Otherwise Escape closes the last open section a person can see,
// inside the top open window when one is open; a window with none open inside
// closes itself.
export function installEscape() {
  document.addEventListener("keydown", event => {
    if (event.key !== "Escape" || event.defaultPrevented) return
    if (document.querySelector(":popover-open")) return

    const layer = [...document.querySelectorAll<HTMLDialogElement>("dialog:modal")].at(-1) ?? document
    const openDetails = [...layer.querySelectorAll<HTMLDetailsElement>("details[open]")]
      .filter(details => details.checkVisibility())
      .at(-1)
    if (!openDetails) return

    openDetails.removeAttribute("open")
    openDetails.querySelector<HTMLElement>(":scope > summary")?.focus()
    event.preventDefault()
  })
}
