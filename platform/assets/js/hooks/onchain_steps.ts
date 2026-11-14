import type {Hook} from "../hook_composition.ts"
import {loadPrivyBridge, privyAppId} from "../privy/account.ts"
import {report} from "../visit_log.ts"
import {
  NothingSent,
  sendFailure,
  sendStep,
  type SelectedWallet,
  type SendFailure,
  type StepChain,
  type TransactionStep,
} from "../wallet_actions/send_step.ts"

// The template's `hooks/onchain_steps.ts` (skill `onchain-buttons`), on
// Patchbay's press-time path: the wallet bridge loads only when someone
// presses, so every press asks the component for the steps to send, built on
// the server for the form as it is on screen, and sends the one it names.

/**
 * Who sends, on which chain, the steps the server built for one press, and
 * the inputs it built them from. It never changes: a new figure is a new
 * review with a new id.
 */
export type Review = {
  id: string
  component_id: string
  signer: string
  chain: StepChain
  steps: TransactionStep[]
  inputs: Record<string, string>
}

/** What the wallet answered one press: the hash, or why nothing was sent. */
export type Pressed = {transaction_hash: string} | {reason: SendFailure}

/** The wallet Privy has active in this tab, or why there is none. */
export type ActiveWallet = () => Promise<SelectedWallet | null>

type Push = (event: string, payload: unknown) => void

type Reply = {reply: unknown}

type OnchainStepsHook = {
  el: HTMLElement
  js(): {ignoreAttributes(el: HTMLElement, attrs: string[]): void}
  pushEventTo(target: HTMLElement, event: string, payload?: unknown): Promise<PromiseSettledResult<Reply>[]>
  clicked?: (event: Event) => void
  // How many presses this component has taken, and the line it is showing.
  pressed: number
  shown: Line
}

// How many of a button's presses the wallet still has. The mark comes off when
// the last one is answered.
const presses = new WeakMap<HTMLElement, number>()

/**
 * The wallet buttons of one server component. The component's root carries
 * the hook and a DOM id; each button names its step with `data-onchain-step`,
 * and each form field the steps depend on is marked `data-onchain-input="name"`.
 */
export const OnchainSteps: Hook = {
  mounted(this: OnchainStepsHook) {
    this.pressed = 0
    this.shown = null
    // A push can take half a minute to give up, so a line about one press is
    // shown only while no newer press has started: said late, "nothing was sent"
    // beside a newer press that went through would have a person send twice.
    const say = (line: Line, during: number) => {
      if (during !== this.pressed) return
      this.shown = line
      note(this.el, line)
    }
    const push = (during: number): Push => (event, payload) => {
      const unheard = () => {
        const {step, reason} = payload as {step?: string; reason?: string}
        const answered = event !== "step_failed" || reason === "send_unconfirmed"
        say(answered ? "unreported" : "lost", during)
        report({name: "press.unsent", where: step ?? event, outcome: "lost"})
      }
      void this.pushEventTo(this.el, event, payload).then(([result]) => {
        if (result?.status !== "fulfilled") unheard()
      }, unheard)
    }

    // Every press runs on its own and reaches the wallet, even while an earlier
    // one is still there.
    this.clicked = event => {
      const button = (event.target as Element | null)?.closest<HTMLElement>("[data-onchain-step]")
      const name = button?.dataset.onchainStep
      if (!button || !name || !this.el.contains(button)) return
      // Signed out, the server marks each button as a sign-in control: the press
      // opens Privy's sign-in (privy/account.ts), and there is no wallet to reach.
      if (button.dataset.accountTarget === "sign-in") return
      // The mark is this island's own, so a page update while the wallet has the
      // press leaves it on the button.
      this.js().ignoreAttributes(button, ["data-awaiting-wallet"])
      const release = mark(button)
      const during = (this.pressed += 1)
      say(null, during)
      void press(this.el, name, activeWallet, (event, payload) => this.pushEventTo(this.el, event, payload), push(during))
        .catch(() => {
          // The server never heard the press, so it cannot say why; the page
          // does, and reports it.
          say("lost", during)
          report({name: "press.unsent", where: name, outcome: "lost"})
        })
        .finally(release)
    }
    this.el.addEventListener("click", this.clicked)
  },

  // A page that rejoins redraws the component, which hides its lines again;
  // the one this hook was showing is put back, so "your wallet answered"
  // outlives the very reconnect it is about. The next press clears it.
  reconnected(this: OnchainStepsHook) {
    note(this.el, this.shown)
  },

  destroyed(this: OnchainStepsHook) {
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
  },
}

/**
 * One press of the step `name` in the component at `root`: asks the server
 * for the steps, built for the form on screen and the wallet Privy has active,
 * and sends the one it names from that wallet. With no wallet active, or one
 * that is not the wallet the steps pay from, nothing is sent and the server's
 * note says which wallet to open. An empty reply
 * means the server found nothing to send and says why on the page. Reports
 * what the wallet answered against the review it sent from, and returns it;
 * the server decides what the hash did. Rejects when the server never heard
 * the press.
 */
export async function press(
  root: HTMLElement,
  name: string,
  wallet: ActiveWallet,
  ask: (event: string, payload: unknown) => Promise<PromiseSettledResult<Reply>[]>,
  push: Push,
): Promise<Pressed | null> {
  let sending = false
  const started = () => {
    sending = true
  }

  try {
    const active = await wallet()
    if (!active) throw new NothingSent("wallet_unavailable")

    const [result] = await ask("prepare_and_send", {step: name, form: formInputs(root), address: active.address})
    if (result?.status !== "fulfilled") throw new Unheard()
    const {review, send} = result.value.reply as {review?: Review; send?: string}
    const step = review?.steps.find(candidate => candidate.step === send)
    if (!review || !step) return null

    const transaction_hash = await sendStep(review.chain, review.signer, step, active, started)
    push("step_sent", {review_id: review.id, step: name, transaction_hash})
    return {transaction_hash}
  } catch (error) {
    if (error instanceof Unheard) throw error
    const reason = sendFailure(sending, error)
    // The form goes too, so the server's note names the wallet the press was for.
    push("step_failed", {step: name, reason, form: formInputs(root)})
    return {reason}
  }
}

// The press never reached the server.
class Unheard extends Error {}

// The wallet Privy has active in this tab when the signed-in account links
// it, read when someone presses.
async function activeWallet(): Promise<SelectedWallet | null> {
  const appId = privyAppId(document)
  const bridge = appId ? await loadPrivyBridge(document) : null
  if (!appId || !bridge) return null
  const answer = await bridge.activeWallet(appId)
  return answer.ok ? answer.wallet : null
}

/**
 * The steps' inputs as they are on screen now: text as typed, a box as
 * "true" or "false", and a group of choices as the one chosen.
 */
export function formInputs(root: HTMLElement): Record<string, string> {
  const inputs: Record<string, string> = {}
  root.querySelectorAll<HTMLInputElement | HTMLSelectElement>("[data-onchain-input]").forEach(input => {
    const name = input.dataset.onchainInput
    if (!name) return
    if (input instanceof HTMLInputElement && input.type === "radio") {
      if (input.checked) inputs[name] = input.value
    } else {
      inputs[name] = input instanceof HTMLInputElement && input.type === "checkbox" ? String(input.checked) : input.value
    }
  })
  return inputs
}

// The component's own two lines for a page without a connection:
// `data-onchain-lost` when the press never reached the server, and
// `data-onchain-unreported` when the wallet answered and the answer could not
// be passed on. `null` hides both; the next render from the server does too.
type Line = "lost" | "unreported" | null

function note(root: HTMLElement, shown: Line): void {
  for (const name of ["lost", "unreported"] as const) {
    const line = root.querySelector<HTMLElement>(`[data-onchain-${name}]`)
    if (line) line.hidden = name !== shown
  }
}

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
