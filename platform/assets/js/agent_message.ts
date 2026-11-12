/**
 * The Agent Message window (`PatchbayWeb.AgentMessage`), from one listener on
 * the document. The button opens the window its `aria-controls` names; a
 * press on the dimmed page around it, which lands on the dialog itself,
 * closes it, as its X and Escape do. Closing gives focus back to the button.
 * Its copy buttons are the page's shared copy listener's.
 */
export function installAgentMessage(doc: Document = globalThis.document) {
  doc.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null
    const opener = target?.closest<HTMLButtonElement>("[data-agent-message-open]")
    const dialog = opener && doc.getElementById(opener.getAttribute("aria-controls") ?? "")

    if (dialog instanceof HTMLDialogElement) {
      dialog.addEventListener("close", () => opener?.focus(), {once: true})
      dialog.showModal()
    } else if (target instanceof HTMLDialogElement && target.matches("[data-agent-message]")) {
      // The dialog's own padding is the dialog too; only a press outside its box closes it.
      const box = target.getBoundingClientRect()
      const outside = event.clientX < box.left || event.clientX > box.right ||
        event.clientY < box.top || event.clientY > box.bottom
      if (outside) target.close()
    }
  })
}
