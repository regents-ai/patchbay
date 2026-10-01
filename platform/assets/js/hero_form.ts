import {errorIn} from "./api_error.ts"
import {payForIntent} from "./webmcp/paid_actions.ts"
import {requestAccountAction} from "./privy/account.ts"
import {keepDraft, restoreDraft, sessionStorageOrNull, type PageForm} from "./form_draft.ts"
import {mountSiteCheck} from "./site_check.ts"
import {mountToolPicker} from "./tool_picker.ts"
import {deny} from "./hooks/motion/press.ts"

const DRAFT_KEY = "pb-hero-draft"
const PICKS_KEY = "pb-hero-draft-tools"
const FIELDS = ["goal", "site_url", "details", "thread_kind", "topic_tags"]
const FIELD_NAMES = FIELDS.map(name => `ask[${name}]`)
const DETAILS = ["ask[details]", "ask[topic_tags]"]
const PREVIEW_PATH = "/threads/preview"
const PICTURES = "ask[pictures][]"
const MOST_PICTURES = 3
const PICTURE_BYTES = 3 * 1024 * 1024
const PICTURE_TYPES = new Set(["image/png", "image/jpeg", "image/webp"])

const WORDS: Record<string, string> = {
  paying: "Asking your wallet to approve the fee.",
  paid: "Paid. Opening your fix.",
  unconfigured: "Paying is not set up on this Patchbay.",
  unloadable: "The wallet window could not be loaded. Check your connection and try again.",
  unready: "The wallet did not answer in time. Try again.",
  signed_out: "Sign in with a wallet first, at the top of the page.",
  wallet_unavailable: "Connect your wallet, then press again. Nothing was sent.",
  wallet_mismatch: "Switch your wallet app to the wallet you signed in with, then press again. Nothing was sent.",
  network_mismatch: "Your wallet is on a different network. Switch it to Base, then press again. Nothing was sent.",
  wallet_declined: "Your wallet declined this. Nothing was sent.",
  sign_unconfirmed: "Your wallet didn't finish approving the fee. Nothing was paid.",
  canceled: "That was canceled before it finished.",
  payment_refused: "The payment was not accepted, so nothing was charged. Check that your wallet holds enough USDC on Base, then press again.",
  unopened: "Paid, and you will not be charged again. The fix could not be opened just now; " +
    "a person at Patchbay will open it for you.",
  unpreviewed: "Your post could not be shown just now. Try again in a moment.",
  too_many_pictures: `Add up to ${MOST_PICTURES} pictures.`,
  picture_too_big: "Each picture can be up to 3 MB.",
  picture_kind: "Pictures can be PNG, JPEG or WebP.",
}

type HeroFormOptions = {
  document?: Document
  fetch?: typeof globalThis.fetch
  csrfToken?: string
  storage?: Storage | null
  navigate?: (url: string) => void
}

type FixRequest = {
  goal: string
  site_url: string
  error: string
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

type NextStep =
  | {navigate: string; problem?: undefined; note?: undefined}
  | {problem: string; note?: string; navigate?: undefined}

// A chosen picture, as far as the page can check it before sending.
type Picture = {size: number; type: string}

/**
 * The form at the top of the home page. What the person is trying to do,
 * the site and the tools they pick either go to Jev, with the button that
 * says what a fix costs right now, or become a forum post. It folds its
 * extra fields away until the person starts typing, keeps what they typed
 * and the tools they picked across a sign-in, and lists the WebMCP tools
 * found at the site to pick from.
 *
 * Jev, once the free fixes are used, pays the fee with the wallet the page
 * is signed in with before opening the fix. Post to the forum shows the post
 * as it will appear, in place so the pictures chosen stay chosen, and its
 * Publish button sends the form, or opens sign-in first.
 */
export function mountHeroForm(options: HeroFormOptions = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-hero-form") as PageForm | null
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
  restorePicks(form, storage)
  openFilledDetails(form)
  foldUntilFocus(form)
  const picker = mountToolPicker(form)
  mountSiteCheck(form, {...options, onTools: picker?.show})

  const keep = () => {
    keepDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
    keepPicks(form, storage)
  }

  // A fix or post that was turned down comes back at the address the form
  // was sent to, which only takes a form. The address of the page the form
  // is on goes back in its place, with what was typed kept, so signing in or
  // reloading returns to this form rather than to a page that is not there.
  const view = doc.defaultView
  const home = form.dataset.pbHome!
  if (view && view.location.pathname !== home) {
    keep()
    view.history.replaceState(view.history.state, "", home)
  }

  // A post is published as it was last shown: anything changed after the
  // preview takes it away, to be shown again.
  const changed = (event: Event) => {
    if (!(event.target as Element).closest?.("#pb-hero-preview")) clearPreview(form)
  }
  form.addEventListener("input", changed)
  form.addEventListener("change", changed)

  form.addEventListener("submit", event => {
    const submitter = event.submitter
    if (submitter?.hasAttribute("data-pb-preview")) {
      event.preventDefault()
      void preview(form, options)
    } else if (submitter?.hasAttribute("data-pb-post")) {
      if (form.dataset.pbSignedIn !== "true") {
        event.preventDefault()
        keep()
        void requestAccountAction("sign-in", doc, options)
      }
    } else if (form.dataset.pbFixMode === "pay") {
      event.preventDefault()
      void pay(form, doc, options)
    } else if (form.dataset.pbFixMode === "sign_in") {
      event.preventDefault()
      keep()
      void requestAccountAction("sign-in", doc, options)
    }
  })
}

/**
 * The request the form's texts and the picked tools make, in the shape
 * Patchbay takes. The page never asks about signing in: Patchbay acts on no
 * one's account, and the form says so.
 */
export function fixArguments(fields: Record<string, string>, tools: string[]): FixRequest {
  const text = (name: string) => (fields[name] ?? "").trim()
  return {
    goal: text("goal"),
    site_url: text("site_url"),
    error: text("details"),
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
  const refused = errorIn(outcome.body)
  if (outcome.unsigned) {
    const note = refused?.wallet_note
    return {problem: WORDS[outcome.unsigned], note: typeof note === "string" ? note : undefined}
  }
  if (outcome.status === 200 && outcome.body?.status === "applied" && outcome.intent?.run_id) {
    return {navigate: fixPath(outcome.intent.run_id as string)}
  }
  if (outcome.status === 409 && refused?.code === "assist_running" && typeof refused.run_id === "string") {
    return {navigate: fixPath(refused.run_id)}
  }
  if (outcome.status === 202 && outcome.intent?.run_id) {
    return {problem: WORDS.unopened}
  }
  if (refused?.code === "payment_refused") return {problem: WORDS.payment_refused}
  const said = refused?.message
  return {problem: typeof said === "string" && said !== "" ? said : "That fix could not be paid for. Nothing was charged unless a wallet approval went through."}
}

/** Why the chosen pictures cannot go with the post, or nothing when they can. */
export function picturesProblem(pictures: Picture[]): string | null {
  if (pictures.length > MOST_PICTURES) return WORDS.too_many_pictures
  if (pictures.some(picture => !PICTURE_TYPES.has(picture.type))) return WORDS.picture_kind
  if (pictures.some(picture => picture.size > PICTURE_BYTES)) return WORDS.picture_too_big
  return null
}

async function pay(form: PageForm, doc: Document, options: HeroFormOptions) {
  say(form, WORDS.paying)
  note(form, null)
  const outcome = await payForIntent(
    {fetch: options.fetch, csrfToken: options.csrfToken, document: doc},
    {kind: "jev_assist", args: fixArguments(fieldsOf(form), picksOf(form))},
  )
  const next = fixOutcome(outcome)
  if (next.navigate) {
    say(form, WORDS.paid)
    ;(options.navigate ?? ((url: string) => globalThis.location.assign(url)))(next.navigate)
  } else {
    note(form, next.note)
    refuse(form, "#pb-fix-submit", next.problem!)
  }
}

// The post as it will appear, asked for without sending the pictures, which
// the page shows itself from the files chosen.
async function preview(form: PageForm, options: HeroFormOptions) {
  const slot = form.querySelector<HTMLElement>("#pb-hero-preview")
  if (!slot || !form.reportValidity()) return

  const pictures = picturesOf(form)
  const problem = picturesProblem(pictures)
  if (problem) return refuse(form, "[data-pb-preview]", problem)

  const body = new FormData(form)
  body.delete(PICTURES)
  try {
    const response = await (options.fetch ?? globalThis.fetch)(PREVIEW_PATH, {
      method: "POST",
      body,
      credentials: "same-origin",
      headers: {accept: "text/html"},
    })
    if (!response.ok) return refuse(form, "[data-pb-preview]", WORDS.unpreviewed)
    clearPreview(form)
    // Patchbay's own page part for this form, words escaped where they were written.
    slot.innerHTML = await response.text()
  } catch {
    return refuse(form, "[data-pb-preview]", WORDS.unpreviewed)
  }
  say(form, "")
  showPictures(slot, pictures)
  slot.querySelector("#pb-hero-post, [role=alert]")?.scrollIntoView({block: "nearest"})
}

function showPictures(slot: HTMLElement, pictures: File[]) {
  const box = slot.querySelector<HTMLElement>("[data-pb-preview-pictures]")
  if (!box) return
  box.replaceChildren(
    ...pictures.map((picture, index) => {
      const image = slot.ownerDocument.createElement("img")
      image.src = URL.createObjectURL(picture)
      image.alt = `Picture ${index + 1} you added`
      return image
    }),
  )
}

function clearPreview(form: PageForm) {
  const slot = form.querySelector<HTMLElement>("#pb-hero-preview")
  if (!slot || slot.childElementCount === 0) return
  for (const image of slot.querySelectorAll<HTMLImageElement>("[data-pb-preview-pictures] img")) {
    URL.revokeObjectURL(image.src)
  }
  slot.replaceChildren()
}

function picturesOf(form: PageForm) {
  const field = form.elements[PICTURES] as HTMLInputElement | undefined
  return Array.from(field?.files ?? [])
}

function fixPath(runId: string) {
  return `/fixes/${encodeURIComponent(runId)}`
}

function foldUntilFocus(form: PageForm) {
  const typed = (form.elements["ask[site_url]"]?.value ?? "") !== ""
  if (typed || form.querySelector("[role=alert]")) return
  form.dataset.pbCollapsed = "true"
  const unfold = () => delete form.dataset.pbCollapsed
  form.addEventListener("focusin", unfold, {once: true})
}

// Details put back after a sign-in are shown, not folded away.
function openFilledDetails(form: PageForm) {
  const details = form.querySelector<HTMLDetailsElement>("#pb-hero-details")
  if (details && DETAILS.some(name => (form.elements[name]?.value ?? "") !== "")) details.open = true
}

function fieldsOf(form: PageForm) {
  return Object.fromEntries(FIELDS.map(name => [name, form.elements[`ask[${name}]`]?.value ?? ""]))
}

function picksOf(form: PageForm) {
  return Array.from(form.querySelectorAll<HTMLInputElement>("input[name='ask[tools][]']:checked"), input => input.value)
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

// The wallet the account does not know, named beside the button. The line is
// always in the page and only shown or hidden, so nothing moves the button.
function note(form: PageForm, words: string | null | undefined) {
  const line = form.querySelector<HTMLElement>("#pb-fix-wallet-note")
  if (!line) return
  line.textContent = words ?? ""
  line.hidden = !words
}

// The reason is said under the buttons, and the button pressed shakes its head.
function refuse(form: PageForm, button: string, words: string) {
  say(form, words)
  deny(form.querySelector(button)!)
}
