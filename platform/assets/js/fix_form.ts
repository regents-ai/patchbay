import {payForIntent} from "./webmcp/paid_actions.ts"
import {requestAccountAction} from "./privy/account.ts"
import {keepDraft, restoreDraft, sessionStorageOrNull, type PageForm} from "./form_draft.ts"
import {mountSiteCheck} from "./site_check.ts"
import {deny} from "./hooks/motion/press.ts"

const DRAFT_KEY = "pb-fix-draft"
const FIELDS = ["goal", "site_url", "expected_result", "sign_in", "tool", "arguments"]
const FIELD_NAMES = FIELDS.map(name => `fix[${name}]`)
const MORE = ["site_url", "expected_result", "tool", "arguments"]

const WORDS: Record<string, string> = {
  paying: "Asking your wallet to approve the fee.",
  paid: "Paid. Opening your fix.",
  unconfigured: "Paying is not set up on this Patchbay.",
  unloadable: "The wallet window could not be loaded. Check your connection and try again.",
  unready: "The wallet did not answer in time. Try again.",
  signed_out: "Sign in with a wallet first, at the top of the page.",
  wallet_unavailable: "Connect your wallet, then press again. Nothing was sent.",
  wallet_mismatch: "Switch to a wallet on your account in your wallet app, then press again. Nothing was sent.",
  network_mismatch: "Your wallet is on a different network. Switch it to Base, then press again. Nothing was sent.",
  wallet_declined: "Your wallet declined this. Nothing was sent.",
  sign_unconfirmed: "Your wallet didn't finish approving the fee. Nothing was paid.",
  canceled: "That was canceled before it finished.",
  unopened: "Paid, and you will not be charged again. The fix could not be opened just now; " +
    "a person at Patchbay will open it for you.",
}

type FixFormOptions = {
  document?: Document
  fetch?: typeof globalThis.fetch
  csrfToken?: string
  storage?: Storage | null
  navigate?: (url: string) => void
}

type BelievedCall = {tool: string; arguments: object}

type FixRequest = {
  goal: string
  site_url: string
  expected_result: string
  sign_in: string
  believed_calls: BelievedCall[]
}

type FixArguments = {ok: true; args: FixRequest; problem?: undefined} | {ok: false; problem: string; args?: undefined}

// Patchbay's last word on a paid fix, as `payForIntent` answers it.
type PaidFix = {
  status: number
  body: Record<string, unknown> | null
  intent?: Record<string, unknown>
  unsigned?: string
}

type NextStep = {navigate: string; problem?: undefined; note?: undefined} | {problem: string; note?: string; navigate?: undefined}

/**
 * The fix form at the top of the home page. It folds its extra fields away
 * until the person starts typing, keeps what they typed across a sign-in,
 * looks for WebMCP tools at the site while the fix is free, and, once the
 * free fixes are used, pays the fee with the wallet the page is signed in
 * with before opening the fix.
 */
export function mountFixForm(options: FixFormOptions = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-fix-form") as PageForm | null
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
  foldUntilFocus(form)
  mountSiteCheck(form, options)

  form.addEventListener("submit", event => {
    const mode = form.dataset.pbFixMode
    if (mode === "pay") {
      event.preventDefault()
      void pay(form, doc, options)
    } else if (mode === "sign_in") {
      event.preventDefault()
      keepDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
      void requestAccountAction("sign-in", doc, options)
    }
  })
}

/**
 * The request the form's fields make, in the shape Patchbay takes, or the
 * words for why they cannot make one.
 */
export function fixArguments(fields: Record<string, string>): FixArguments {
  const text = (name: string) => (fields[name] ?? "").trim()
  const tool = text("tool")
  let believed_calls: BelievedCall[] = []

  if (tool !== "") {
    const raw = text("arguments")
    let parsed: unknown = {}
    if (raw !== "") {
      try {
        parsed = JSON.parse(raw)
      } catch {
        parsed = null
      }
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {ok: false, problem: 'Write the arguments as a JSON object, like {"party": 2}.'}
    }
    believed_calls = [{tool, arguments: parsed}]
  }

  return {
    ok: true,
    args: {
      goal: text("goal"),
      site_url: text("site_url"),
      expected_result: text("expected_result"),
      sign_in: text("sign_in") || "unknown",
      believed_calls,
    },
  }
}

/**
 * What to do with Patchbay's last word on a paid fix: go to the fix once
 * the payment was applied, or to the fix already under way, which nothing
 * was charged for; otherwise say what stood in the way.
 */
export function fixOutcome(outcome: PaidFix): NextStep {
  if (outcome.unsigned) {
    const note = outcome.body?.wallet_note
    return {problem: WORDS[outcome.unsigned], note: typeof note === "string" ? note : undefined}
  }
  if (outcome.status === 200 && outcome.body?.status === "applied" && outcome.intent?.run_id) {
    return {navigate: fixPath(outcome.intent.run_id as string)}
  }
  if (outcome.status === 409 && outcome.body?.problem_code === "assist_running" && outcome.body.run_id) {
    return {navigate: fixPath(outcome.body.run_id as string)}
  }
  if (outcome.status === 202 && outcome.intent?.run_id) {
    return {problem: WORDS.unopened}
  }
  const said = outcome.body?.reason ?? outcome.body?.error
  return {problem: typeof said === "string" && said !== "" ? said : "That fix could not be paid for. Nothing was charged unless a wallet approval went through."}
}

async function pay(form: PageForm, doc: Document, options: FixFormOptions) {
  const request = fixArguments(fieldsOf(form))
  if (!request.ok) return refuse(form, request.problem)

  say(form, WORDS.paying)
  note(form, null)
  const outcome = await payForIntent(
    {fetch: options.fetch, csrfToken: options.csrfToken, document: doc},
    {kind: "jev_assist", args: request.args},
  )
  const next = fixOutcome(outcome)
  if (next.navigate) {
    say(form, WORDS.paid)
    ;(options.navigate ?? ((url: string) => globalThis.location.assign(url)))(next.navigate)
  } else {
    note(form, next.note)
    refuse(form, next.problem!)
  }
}

function fixPath(runId: string) {
  return `/fixes/${encodeURIComponent(runId)}`
}

function foldUntilFocus(form: PageForm) {
  const typed = MORE.some(name => (form.elements[`fix[${name}]`]?.value ?? "") !== "")
  if (typed || form.querySelector("[role=alert]")) return
  form.dataset.pbCollapsed = "true"
  const unfold = () => delete form.dataset.pbCollapsed
  form.addEventListener("focusin", unfold, {once: true})
}

function fieldsOf(form: PageForm) {
  return Object.fromEntries(FIELDS.map(name => [name, form.elements[`fix[${name}]`]?.value ?? ""]))
}

function say(form: PageForm, words: string) {
  const status = form.querySelector("#pb-fix-status")
  if (status) status.textContent = words
}

// The wallet the account does not know, named beside the button. The line is
// always in the page and only shown or hidden, so nothing moves the button.
function note(form: PageForm, words: string | null | undefined) {
  const line = form.querySelector<HTMLElement>("#pb-fix-wallet-note")
  if (!line) return
  line.textContent = words ?? ""
  line.hidden = !words
}

// The reason is said beside the button, and the button shakes its head.
function refuse(form: PageForm, words: string) {
  say(form, words)
  deny(form.querySelector("[type=submit]")!)
}
