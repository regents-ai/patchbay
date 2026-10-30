/**
 * The Buy Credits panel's wallet buttons and the dialog that holds it, as in
 * the Regent template's `OnchainSteps` hook. The server builds each step and
 * pushes it to the page before anyone presses; every press reaches Privy's
 * active wallet, even while an earlier one is still there, and reports only
 * what the wallet answered. Privy lives in a bundle of its own here, so the
 * wallet is read from it when the panel opens, when the page comes back into
 * view and at each press, rather than followed as it changes.
 */
import type {Hook, HookInterface} from "phoenix_live_view"

import {loadPrivyBridge, privyAppId} from "../privy/account.ts"
import {report} from "../visit_log.ts"
import type {MetaDocument, PrivyBridgeModule} from "../privy/account.ts"
import {sendFailure, sendStep} from "../wallet_actions/send_step.ts"
import type {SelectedWallet, StepChain, TransactionStep} from "../wallet_actions/send_step.ts"

/**
 * Who sends, on which chain, the steps the buttons name, and the on-screen
 * inputs they were built from, all on the server. A new figure is a new review.
 */
export type Review = {
  id: string
  component_id: string
  signer: string
  chain: StepChain
  steps: TransactionStep[]
  inputs: Record<string, string>
}

export type Push = (event: string, payload: unknown) => void

/**
 * Privy's active wallet for this press, or why there is none: Privy could not
 * be reached (`wallet_unreachable`), holds no sign-in in this browser
 * (`privy_signed_out`), or has no wallet open (`wallet_unavailable`; nothing
 * opens, and the server's note asks the person to open one of their wallets).
 */
export type PressWallet =
  | {ok: true; wallet: SelectedWallet}
  | {ok: false; reason: "wallet_unreachable" | "privy_signed_out" | "wallet_unavailable"}

type LoadBridge = (doc: MetaDocument) => Promise<Pick<PrivyBridgeModule, "activeWallet" | "activeAddress"> | null>

export async function pressWallet(doc: MetaDocument, loadBridge: LoadBridge = loadPrivyBridge): Promise<PressWallet> {
  const appId = privyAppId(doc)
  const bridge = appId && (await loadBridge(doc))
  if (!appId || !bridge) return {ok: false, reason: "wallet_unreachable"}

  const found = await bridge.activeWallet(appId)
  if (found.ok) return found
  if (found.reason === "signed_out") return {ok: false, reason: "privy_signed_out"}
  if (found.reason === "wallet_unavailable") return {ok: false, reason: "wallet_unavailable"}
  return {ok: false, reason: "wallet_unreachable"}
}

/** Privy's active wallet, read without opening anything; null with none. */
export async function activeAddress(doc: MetaDocument, loadBridge: LoadBridge = loadPrivyBridge): Promise<string | null> {
  const appId = privyAppId(doc)
  const bridge = appId && (await loadBridge(doc))
  return appId && bridge ? bridge.activeAddress(appId) : null
}

/**
 * Sends the named step from `wallet`, and reports what the wallet answered
 * against the review it was sent from: the hash, or why nothing was sent.
 * The server decides what the hash did.
 */
export async function press(review: Review, name: string, wallet: SelectedWallet, push: Push): Promise<void> {
  const step = review.steps.find(candidate => candidate.step === name)
  if (!step) return push("step_failed", {step: name, reason: "step_unknown"})

  let sending = false
  try {
    const transaction_hash = await sendStep(review.chain, review.signer, step, wallet, () => {
      sending = true
    })
    push("step_sent", {review_id: review.id, step: name, transaction_hash})
  } catch (error) {
    push("step_failed", {step: name, reason: sendFailure(sending, error)})
  }
}

/**
 * The review's inputs as they are on screen now: text as typed, and a group
 * of choices as the one chosen.
 */
export function formInputs(root: ParentNode): Record<string, string> {
  const inputs: Record<string, string> = {}
  root.querySelectorAll<HTMLInputElement>("[data-onchain-input]").forEach(input => {
    const name = input.dataset.onchainInput
    if (name && (input.type !== "radio" || input.checked)) inputs[name] = input.value
  })
  return inputs
}

/** Whether a press can send `review` as it stands, or must ask the server first. */
export function current(review: Review | undefined, wallet: SelectedWallet, form: Record<string, string>): review is Review {
  if (!review || review.signer.toLowerCase() !== wallet.address.toLowerCase()) return false
  const names = new Set([...Object.keys(review.inputs), ...Object.keys(form)])
  return [...names].every(name => review.inputs[name] === form[name])
}

type CreditsPanel = {
  review?: Review
  clicked?: (event: Event) => void
  looked?: () => void
}

/**
 * The panel's root carries the hook and a DOM id; each button names its step
 * with `data-onchain-step`, and each field the review depends on is marked
 * `data-onchain-input="name"`. The server hears Privy's active wallet
 * (`onchain_active_wallet`) and reads the funds again (`refresh_funds`) when
 * the panel opens, each time its dialog opens (`pb:refresh-funds` on the root),
 * whenever the page comes back into view and after each press.
 */
export const PatchbayCreditsPanel: Hook<CreditsPanel> = {
  mounted() {
    const push: Push = (event, payload) => void this.pushEventTo(this.el, event, payload)

    // Every hook on the page hears this; keep only this panel's review.
    this.handleEvent("onchain-steps:review", payload => {
      const {component_id, review} = payload as {component_id: string; review: Review | null}
      if (component_id === this.el.id) this.review = review ?? undefined
    })

    this.looked = () =>
      void activeAddress(document).then(address => {
        push("onchain_active_wallet", {address})
        push("refresh_funds", {})
      })
    this.looked()
    window.addEventListener("focus", this.looked)
    this.el.addEventListener("pb:refresh-funds", this.looked)

    // Every press runs on its own and reaches the wallet, even while an earlier
    // one is still there.
    this.clicked = event => {
      const button = (event.target as Element | null)?.closest<HTMLElement>("[data-onchain-step]")
      const name = button?.dataset.onchainStep
      if (!button || !name || !this.el.contains(button)) return
      const release = mark(button)
      lost(this.el, false)

      void pressed(this, name, push)
        .catch(() => lost(this.el, true))
        .finally(() => {
          release()
          // The press may have spent funds or changed what the wallet allows.
          push("refresh_funds", {})
        })
    }
    this.el.addEventListener("click", this.clicked)
  },

  destroyed() {
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    if (this.looked) {
      window.removeEventListener("focus", this.looked)
      this.el.removeEventListener("pb:refresh-funds", this.looked)
    }
  },
}

// Tells the server the wallet Privy has active at the press, then sends the
// review as it stands, or asks the server for the one matching the wallet and
// the form on screen and sends what comes back.
async function pressed(hook: CreditsPanel & HookInterface, name: string, push: Push): Promise<void> {
  const found = await pressWallet(document)
  if (!found.ok) {
    if (found.reason === "wallet_unavailable") push("onchain_active_wallet", {address: null})
    return push("step_failed", {step: name, reason: found.reason})
  }

  const {wallet} = found
  push("onchain_active_wallet", {address: wallet.address})
  const form = formInputs(hook.el)
  if (current(hook.review, wallet, form)) return press(hook.review, name, wallet, push)

  const [result] = await hook.pushEventTo(hook.el, "prepare_and_send", {form, step: name})
  // The server never heard the press, so it cannot say why; the page does, and
  // reports it.
  if (result?.status !== "fulfilled") {
    lost(hook.el, true)
    return report({name: "press.unsent", where: name, outcome: "lost"})
  }
  const reply = result.value.reply as {review?: Review; send?: string}
  if (reply.review && reply.send) return press(reply.review, reply.send, wallet, push)
  push("step_failed", {step: name, reason: "step_unknown"})
}

// The panel's `data-onchain-lost` line, shown when a press could not reach the
// server. The next render from the server hides it again.
function lost(root: HTMLElement, shown: boolean): void {
  const line = root.querySelector<HTMLElement>("[data-onchain-lost]")
  if (line) line.hidden = !shown
}

// How many of a button's presses the wallet still has. The mark comes off when
// the last one is answered.
const presses = new WeakMap<HTMLElement, number>()

// Marked with a data attribute and CSS only: the button keeps taking presses.
function mark(button: HTMLElement): () => void {
  presses.set(button, (presses.get(button) ?? 0) + 1)
  button.dataset.awaitingWallet = "true"

  return () => {
    const left = (presses.get(button) ?? 1) - 1
    presses.set(button, left)
    if (left <= 0) delete button.dataset.awaitingWallet
  }
}

type CreditsDialog = {opened?: () => void}

/**
 * The dialog the account menu's balance opens, and any page's Buy Credits button
 * (`JS.dispatch("pb:credits-open", to: "#pb-credits")`). The server draws the
 * panel inside it once it has been opened; each later opening reads the
 * wallet's funds again, so Buy is held back only by what the chain says now.
 */
export const PatchbayCreditsDialog: Hook<CreditsDialog> = {
  mounted() {
    this.opened = () => {
      const dialog = this.el as HTMLDialogElement
      if (dialog.open) return
      dialog.showModal()
      this.pushEvent("opened", {})
      dialog
        .querySelectorAll("[data-refresh-funds]")
        .forEach(panel => panel.dispatchEvent(new CustomEvent("pb:refresh-funds")))
    }
    this.el.addEventListener("pb:credits-open", this.opened)
  },

  destroyed() {
    if (this.opened) this.el.removeEventListener("pb:credits-open", this.opened)
  },
}
