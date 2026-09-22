import {payForIntent, payFromCredits} from "./webmcp/paid_actions.js"
import {requestAccountAction} from "./privy/account.js"

const DRAFT_KEY = "pb-fix-draft"
const FIELDS = ["goal", "site_url", "expected_result", "sign_in", "tool", "arguments"]
const MORE = ["site_url", "expected_result", "tool", "arguments"]

const WORDS = {
  paying: "Asking the wallet you signed in with to approve the fee.",
  spending: "Paying from your Patchbay Credits.",
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

/**
 * The fix form at the top of the home page. It folds its extra fields away
 * until the person starts typing, keeps what they typed across a sign-in,
 * and, once the free fixes are used, pays the fee with the wallet the page
 * is signed in with, or from the person's Patchbay Credits when they press
 * that button, before opening the fix.
 *
 * @param {{document?: Document, fetch?: typeof globalThis.fetch, csrfToken?: string, storage?: Storage | null, navigate?: (url: string) => void}} [options]
 */
export function mountFixForm(options = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-fix-form")
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage)
  foldUntilFocus(form)

  form.addEventListener("submit", event => {
    const mode = form.dataset.pbFixMode
    if (mode === "pay") {
      event.preventDefault()
      void pay(form, doc, options, event.submitter?.value === "credits")
    } else if (mode === "sign_in") {
      event.preventDefault()
      keepDraft(form, storage)
      void requestAccountAction("sign-in", doc, options)
    }
  })
}

/**
 * The request the form's fields make, in the shape Patchbay takes, or the
 * words for why they cannot make one.
 *
 * @param {Record<string, string>} fields
 * @returns {{ok: true, args: object} | {ok: false, problem: string}}
 */
export function fixArguments(fields) {
  const text = name => (fields[name] ?? "").trim()
  const tool = text("tool")
  let believed_calls = []

  if (tool !== "") {
    const raw = text("arguments")
    let parsed = {}
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
 *
 * @param {{status: number, body: object | null, intent?: object, unsigned?: string}} outcome
 * @returns {{navigate: string} | {problem: string}}
 */
export function fixOutcome(outcome) {
  if (outcome.unsigned) return {problem: WORDS[outcome.unsigned] ?? WORDS.refused}
  if (outcome.status === 200 && outcome.body?.status === "applied" && outcome.intent?.run_id) {
    return {navigate: fixPath(outcome.intent.run_id)}
  }
  if (outcome.status === 409 && outcome.body?.problem_code === "assist_running" && outcome.body.run_id) {
    return {navigate: fixPath(outcome.body.run_id)}
  }
  if (outcome.status === 202 && outcome.intent?.run_id) {
    return {problem: WORDS.unopened}
  }
  const said = outcome.body?.error
  return {problem: typeof said === "string" && said !== "" ? said : "That fix could not be paid for. Nothing was charged unless a wallet approval went through."}
}

async function pay(form, doc, options, fromCredits) {
  const request = fixArguments(fieldsOf(form))
  if (!request.ok) return say(form, request.problem)

  const action = {kind: "jev_assist", args: request.args}
  say(form, fromCredits ? WORDS.spending : WORDS.paying)
  const outcome = fromCredits
    ? await payFromCredits({fetch: options.fetch, csrfToken: options.csrfToken}, action)
    : await payForIntent({fetch: options.fetch, csrfToken: options.csrfToken, document: doc}, action)
  const next = fixOutcome(outcome)
  if (next.navigate) {
    say(form, WORDS.paid)
    ;(options.navigate ?? (url => globalThis.location.assign(url)))(next.navigate)
  } else {
    say(form, next.problem)
  }
}

function fixPath(runId) {
  return `/fixes/${encodeURIComponent(runId)}`
}

function foldUntilFocus(form) {
  const typed = MORE.some(name => (form.elements[`fix[${name}]`]?.value ?? "") !== "")
  if (typed || form.querySelector("[role=alert]")) return
  form.dataset.pbCollapsed = "true"
  const unfold = () => delete form.dataset.pbCollapsed
  form.addEventListener("focusin", unfold, {once: true})
}

function fieldsOf(form) {
  return Object.fromEntries(FIELDS.map(name => [name, form.elements[`fix[${name}]`]?.value ?? ""]))
}

function keepDraft(form, storage) {
  try {
    storage?.setItem(DRAFT_KEY, JSON.stringify(fieldsOf(form)))
  } catch {
    // A page that cannot keep the draft still signs in.
  }
}

function restoreDraft(form, storage) {
  let kept
  try {
    kept = storage?.getItem(DRAFT_KEY)
    storage?.removeItem(DRAFT_KEY)
  } catch {
    return
  }
  if (!kept) return
  let draft
  try {
    draft = JSON.parse(kept)
  } catch {
    return
  }
  for (const name of FIELDS) {
    const field = form.elements[`fix[${name}]`]
    if (field && typeof draft[name] === "string" && field.value === "") field.value = draft[name]
  }
}

function say(form, words) {
  const status = form.querySelector("#pb-fix-status")
  if (status) status.textContent = words
}

function sessionStorageOrNull() {
  try {
    return globalThis.sessionStorage ?? null
  } catch {
    return null
  }
}
