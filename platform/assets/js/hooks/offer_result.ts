import type {Hook} from "phoenix_live_view"

type OfferResult = {closed?: () => void}

// Native dialogs own modal focus, Escape and focus restoration. The server
// renders this only after the bidder's committed result confirms the refund.
export const PatchbayOfferResultDialog: Hook<OfferResult> = {
  mounted() {
    const dialog = this.el as HTMLDialogElement
    this.closed = () => this.pushEvent("dismiss_outbid", {})
    dialog.addEventListener("close", this.closed)
    dialog.showModal()
  },

  destroyed() {
    if (this.closed) this.el.removeEventListener("close", this.closed)
  },
}
