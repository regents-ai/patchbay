// The account menu at the top right of every page (PatchbayWeb.HeaderAccountLive),
// as in the Regent template's shell_panels.ts. The menu is a popover the browser
// opens and closes itself, so it closes on Escape or a press anywhere else; what is
// ours is following a link inside it, its Pair New Agent, which opens the pairing
// window, and arriving at what an address's #fragment names.

/**
 * Brings `target`, what an address's #fragment names, into view. When it holds a
 * choice, focus goes to the chosen one, or the first, so the keyboard starts there.
 */
export function arriveAt(target: HTMLElement) {
  target.scrollIntoView()
  const choices = [...target.querySelectorAll<HTMLInputElement>("input[type=radio]")]
  const choice = choices.find(radio => radio.checked) ?? choices[0]
  // Next frame: following the link, and LiveView's patch, each move focus first.
  if (choice) requestAnimationFrame(() => choice.focus({preventScroll: true}))
}

const hashTarget = () => {
  const id = decodeURIComponent(window.location.hash.slice(1))
  return id ? document.getElementById(id) : null
}

const arriveAtHash = () => {
  const named = hashTarget()
  if (named) arriveAt(named)
}

const pairing = () => document.getElementById("pb-pairing") as HTMLDialogElement | null

// The pairing window opens on the list of agents while none is chosen, with the
// keyboard on the dropdown.
const openPairing = () => {
  const dialog = pairing()
  if (!dialog || dialog.open) return
  dialog.showModal()
  const pick = dialog.querySelector<HTMLDetailsElement>("details.rg-pill-select")
  if (!pick) return
  if (!pick.querySelector("input:checked")) pick.open = true
  pick.querySelector<HTMLElement>(":scope > summary")?.focus()
}

export function installAccountMenu() {
  document.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    // Pair New Agent, in the account menu and on the Agents page, opens the one
    // pairing window. The menu closes first, so focus goes back to the account
    // button and returns there when the window closes.
    const pairOpener = target.closest<HTMLElement>("[data-pair-open]")
    if (pairOpener) {
      pairOpener.closest<HTMLElement>("[popover]")?.hidePopover()
      return openPairing()
    }
    // A press on the window's own backdrop lands on the dialog itself.
    if (target === pairing()) return pairing()?.close()

    // A page change keeps an open menu open, so a link followed from one closes it.
    // A link to a #fragment of this page changes nothing LiveView sees when the
    // address already shows it, so what it names comes into view here, every press.
    const link = target.closest<HTMLAnchorElement>("a[href]")
    if (!link) return
    link.closest<HTMLElement>("[popover]")?.hidePopover()
    const named = link.hash && link.pathname === window.location.pathname
      ? document.getElementById(decodeURIComponent(link.hash.slice(1)))
      : null
    if (named) arriveAt(named)
  })

  // LiveView records a new address only once its page is drawn, so what a
  // #fragment names is reached here; a page opened at one reaches it once its live
  // part has joined.
  window.addEventListener("phx:navigate", arriveAtHash)
  window.addEventListener("phx:page-loading-stop", event => {
    if ((event as CustomEvent<{kind?: string}>).detail?.kind === "initial") arriveAtHash()
  })
}
