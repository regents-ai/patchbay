import {payForIntent} from "./webmcp/paid_actions.ts"
import {requestAccountAction} from "./privy/account.ts"
import {keepDraft, restoreDraft, sessionStorageOrNull, type PageForm} from "./form_draft.ts"
import {mountSiteCheck} from "./site_check.ts"
import {mountToolPicker} from "./tool_picker.ts"
import {deny} from "./hooks/motion/press.ts"

const DRAFT_KEY = "pb-fix-draft"
const PICKS_KEY = "pb-fix-draft-tools"
const FIELDS = ["goal", "site_url"]
const FIELD_NAMES = FIELDS.map(name => `fix[${name}]`)

const WORDS: Record<string, string> = {
  paying: "Asking the wallet you signed in with to approve the fee.",
  paid: "Paid. Opening your fix.",
  unconfigured: "Paying is not set up on this Patchbay.",
  unloadable: "The wallet window could not be loaded. Check your connection and try again.",
  unready: "The wallet did not answer in time. Try again.",
  closed: "That approval was closed before it finished.",
  refused: "The wallet did not approve the fee.",
  no_wallet: "Sign in with a wallet first, at the top of the page.",
  unsupported_challenge: "This Patchbay asked for a payment this page cannot make.",
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

type FixRequest = {
  goal: string
  site_url: string
  sign_in: "unknown"
  believed_calls: {tool: string}[]
}

// Patchbay's last word on a paid fix, as `payForIntent` answers it.
type PaidFix = {
  status: number
  body: Record<string, unknown> | null
  intent?: Record<string, unknown>
  unsigned?: string
}

type NextStep = {navigate: string; problem?: undefined} | {problem: string; navigate?: undefined}

/**
 * The fix form at the top of the home page. It folds its extra fields away
 * until the person starts typing, keeps what they typed and the tools they
 * picked across a sign-in, lists the WebMCP tools found at the site to pick
 * from, and, once the free fixes are used, pays the fee with the wallet the
 * page is signed in with before opening the fix.
 */
export function mountFixForm(options: FixFormOptions = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-fix-form") as PageForm | null
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
  restorePicks(form, storage)
  foldUntilFocus(form)
  const picker = mountToolPicker(form)
  mountSiteCheck(form, {...options, onTools: picker?.show})

  form.addEventListener("submit", event => {
    const mode = form.dataset.pbFixMode
    if (mode === "pay") {
      event.preventDefault()
      void pay(form, doc, options)
    } else if (mode === "sign_in") {
      event.preventDefault()
      keepDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
      keepPicks(form, storage)
      void requestAccountAction("sign-in", doc, options)
    }
  })
}

/**
 * The request the form's two texts and the picked tools make, in the shape
 * Patchbay takes. The page never asks about signing in: Patchbay acts on no
 * one's account, and the form says so.
 */
export function fixArguments(fields: Record<string, string>, tools: string[]): FixRequest {
  const text = (name: string) => (fields[name] ?? "").trim()
  return {
    goal: text("goal"),
    site_url: text("site_url"),
    sign_in: "unknown",
    believed_calls: tools.map(tool => ({tool})),
  }
}

/**
 * What to do with Patchbay's last word on a paid fix: go to the fix once
 * the payment was applied, or to the fix already under way, which nothing
 * was charged for; otherwise say what stood in the way.
 */
export function fixOutcome(outcome: PaidFix): NextStep {
  if (outcome.unsigned) return {problem: WORDS[outcome.unsigned] ?? WORDS.refused}
  if (outcome.status === 200 && outcome.body?.status === "applied" && outcome.intent?.run_id) {
    return {navigate: fixPath(outcome.intent.run_id as string)}
  }
  if (outcome.status === 409 && outcome.body?.problem_code === "assist_running" && outcome.body.run_id) {
    return {navigate: fixPath(outcome.body.run_id as string)}
  }
  if (outcome.status === 202 && outcome.intent?.run_id) {
    return {problem: WORDS.unopened}
  }
  const said = outcome.body?.error
  return {problem: typeof said === "string" && said !== "" ? said : "That fix could not be paid for. Nothing was charged unless a wallet approval went through."}
}

async function pay(form: PageForm, doc: Document, options: FixFormOptions) {
  say(form, WORDS.paying)
  const outcome = await payForIntent(
    {fetch: options.fetch, csrfToken: options.csrfToken, document: doc},
    {kind: "jev_assist", args: fixArguments(fieldsOf(form), picksOf(form))},
  )
  const next = fixOutcome(outcome)
  if (next.navigate) {
    say(form, WORDS.paid)
    ;(options.navigate ?? ((url: string) => globalThis.location.assign(url)))(next.navigate)
  } else {
    refuse(form, next.problem!)
  }
}

function fixPath(runId: string) {
  return `/fixes/${encodeURIComponent(runId)}`
}

function foldUntilFocus(form: PageForm) {
  const typed = (form.elements["fix[site_url]"]?.value ?? "") !== ""
  if (typed || form.querySelector("[role=alert]")) return
  form.dataset.pbCollapsed = "true"
  const unfold = () => delete form.dataset.pbCollapsed
  form.addEventListener("focusin", unfold, {once: true})
}

function fieldsOf(form: PageForm) {
  return Object.fromEntries(FIELDS.map(name => [name, form.elements[`fix[${name}]`]?.value ?? ""]))
}

function picksOf(form: PageForm) {
  return Array.from(form.querySelectorAll<HTMLInputElement>("input[name='fix[tools][]']:checked"), input => input.value)
}

// The picked tools ride across a sign-in the way the texts do, and the
// list takes them back once it is shown again.
function keepPicks(form: PageForm, storage: Storage | null) {
  try {
    storage?.setItem(PICKS_KEY, picksOf(form).join("\n"))
  } catch {
    // A page that cannot keep the picks still signs in.
  }
}

function restorePicks(form: PageForm, storage: Storage | null) {
  const box = form.querySelector<HTMLElement>("#pb-fix-tools")
  try {
    const kept = storage?.getItem(PICKS_KEY)
    storage?.removeItem(PICKS_KEY)
    if (box && kept) box.dataset.pbPicked = kept
  } catch {
    // Nothing kept, nothing to put back.
  }
}

function say(form: PageForm, words: string) {
  const status = form.querySelector("#pb-fix-status")
  if (status) status.textContent = words
}

// The reason is said beside the button, and the button shakes its head.
function refuse(form: PageForm, words: string) {
  say(form, words)
  deny(form.querySelector("[type=submit]")!)
}
