import type {Hook} from "phoenix_live_view"

type ConfirmDialog = {closed?: () => void}

// A confirmation the server renders when the page address asks for one.
// The native dialog owns modal focus, Escape and focus restoration; closing
// it without confirming tells the server, named by `data-close-event`.
export const PatchbayConfirmDialog: Hook<ConfirmDialog> = {
  mounted() {
    const dialog = this.el as HTMLDialogElement
    const event = dialog.dataset.closeEvent!
    this.closed = () => this.pushEvent(event, {})
    dialog.addEventListener("close", this.closed)
    dialog.showModal()
  },

  destroyed() {
    if (this.closed) this.el.removeEventListener("close", this.closed)
  },
}
