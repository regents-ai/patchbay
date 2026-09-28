import {refusal} from "../api_error.ts"
import type {ErrorBody} from "../api_error.ts"
import type * as PrivyBridge from "../privy_bridge.tsx"

const SESSION_PATH = "/auth/privy/session"

const MESSAGES = {
  unconfigured: "Signing in is not set up on this Patchbay.",
  opening: "Opening the sign-in window.",
  signing_in: "Checking that sign-in.",
  signing_out: "Signing out.",
  unloadable: "The sign-in window could not be loaded. Check your connection and try again.",
  unready: "Privy did not answer in time. Try again.",
  closed: "That sign-in was closed before it finished.",
  refused: "Privy could not finish that sign-in. Try again.",
  no_access_token: "Privy did not hand back the proof Patchbay needs. Try again.",
  no_identity_token: "Privy did not hand back the proof Patchbay needs. Try again.",
  unreachable: "Patchbay could not be reached.",
  refused_locally: "That sign-in could not be verified.",
  sign_out_failed: "Signing out did not go through. Try again.",
}

export type PrivyBridgeModule = typeof PrivyBridge

/**
 * The part of a document the Privy meta tags are read from: anything that can
 * find an element and read one of its attributes.
 */
export type MetaDocument = {
  querySelector(selectors: string): {getAttribute(name: string): string | null} | null
}

type AccountOptions = {
  document?: Document
  fetch?: typeof globalThis.fetch
  csrfToken?: string
  location?: {reload?: () => void}
}

type Say = (message: string) => void

// What the session endpoint answers with; only its refusal's words are read.
type SessionBody = {error?: ErrorBody}

type SessionAnswer = {ok: boolean, body?: SessionBody | null}

// A refusal is read to the visitor whole: what went wrong, then what to do.
function spoken(error: ErrorBody | undefined): string | undefined {
  return error && `${error.message} ${error.hint}`
}

/**
 * Wires the account strip in the root layout to Privy.
 *
 * The strip is the same on every page and is drawn from the signed session, so
 * this only has to answer two clicks. Nothing here reconciles state on load: a
 * Privy that is still waking up says nothing about whether this browser is
 * signed in to Patchbay, and the page already knows the answer to that.
 */
export function installAccountControl(options: AccountOptions = {}) {
  const doc = options.document ?? globalThis.document
  const strip = doc?.getElementById?.("pb-account")
  if (!strip) return

  let running = false

  strip.addEventListener("click", async event => {
    const button = (event.target as Element).closest?.<HTMLButtonElement>("[data-pb-account]")
    if (!button || running) return

    running = true
    button.disabled = true

    try {
      await requestAccountAction(button.dataset.pbAccount!, doc, options)
    } finally {
      running = false
      button.disabled = false
    }
  })
}

const accountAttempts = new WeakMap<Document, Promise<void>>()

export function requestAccountAction(action: string, doc: Document, options: AccountOptions = {}): Promise<void> {
  const existing = accountAttempts.get(doc)
  if (existing) return existing
  const attempt = performAccountAction(action, doc, options)
  accountAttempts.set(doc, attempt)
  void attempt.finally(() => {
    if (accountAttempts.get(doc) === attempt) accountAttempts.delete(doc)
  }).catch(() => {})
  return attempt
}

async function performAccountAction(action: string, doc: Document, options: AccountOptions = {}): Promise<void> {
  const appId = privyAppId(doc)
  const say: Say = message => report(doc, message)

  if (!appId) return say(MESSAGES.unconfigured)

  const bridge = await loadPrivyBridge(doc)
  if (!bridge) return say(MESSAGES.unloadable)

  if (action === "sign-in") return signIn(bridge, appId, options, say)
  return signOut(bridge, appId, options, say)
}

async function signIn(bridge: PrivyBridgeModule, appId: string, options: AccountOptions, say: Say): Promise<void> {
  say(MESSAGES.opening)

  const proof = await bridge.signIn(appId)
  if (!proof.ok) return say((MESSAGES as Partial<Record<string, string>>)[proof.reason] ?? MESSAGES.refused)

  say(MESSAGES.signing_in)

  const answer = await call(options, "POST", {
    authorization: `Bearer ${proof.access}`,
    "privy-id-token": proof.identity,
  })

  // The page is drawn from the session, so the session is what a reload reads.
  if (answer.ok) return reload(options)

  say(spoken(answer.body?.error) ?? MESSAGES.refused_locally)
}

// The Patchbay session goes first, because that is the one this page is drawn
// from. Ending the Privy session behind it is cleanup: if it fails, the visitor
// is still signed out of Patchbay, and saying otherwise would be untrue.
async function signOut(bridge: PrivyBridgeModule, appId: string, options: AccountOptions, say: Say): Promise<void> {
  say(MESSAGES.signing_out)

  const answer = await call(options, "DELETE", {})
  if (!answer.ok) return say(spoken(answer.body?.error) ?? MESSAGES.sign_out_failed)

  try {
    await bridge.signOut(appId)
  } catch {
    // Cleanup only. The visitor is signed out either way.
  }

  reload(options)
}

/**
 * The Privy application this page signs in against, from the page's own meta
 * tag, or null where signing in is not set up.
 */
export function privyAppId(doc: MetaDocument | undefined): string | null {
  return metaContent(doc, "privy-app-id")
}

/**
 * Loads the Privy bridge bundle the page names, or null when it cannot be
 * loaded. Shared by everything that signs through Privy, so the wallet is
 * reached the same way wherever it is asked for something.
 */
export async function loadPrivyBridge(doc: MetaDocument | undefined): Promise<PrivyBridgeModule | null> {
  const source = metaContent(doc, "privy-bridge-src")
  if (!source) return null

  try {
    return (await import(source)) as PrivyBridgeModule
  } catch {
    return null
  }
}

async function call(options: AccountOptions, method: string, headers: Record<string, string>): Promise<SessionAnswer> {
  const fetchImpl = options.fetch ?? globalThis.fetch
  if (typeof fetchImpl !== "function") return {ok: false}

  try {
    const response = await fetchImpl(SESSION_PATH, {
      method,
      credentials: "same-origin",
      headers: {accept: "application/json", "x-csrf-token": options.csrfToken ?? "", ...headers},
    })

    return {ok: response.ok === true, body: await readBody(response)}
  } catch {
    return {ok: false, body: refusal("unreachable", MESSAGES.unreachable, "Check your connection and try again.")}
  }
}

async function readBody(response: Response): Promise<SessionBody | null> {
  try {
    return await response.json()
  } catch {
    return null
  }
}

function reload(options: AccountOptions) {
  const location = options.location ?? globalThis.location
  location?.reload?.()
}

function report(doc: Document, message: string) {
  const note = doc.getElementById("pb-account-note")
  if (note) note.textContent = message
}

function metaContent(doc: MetaDocument | undefined, name: string): string | null {
  const content = doc?.querySelector?.(`meta[name="${name}"]`)?.getAttribute("content")
  const trimmed = typeof content === "string" ? content.trim() : ""
  return trimmed === "" ? null : trimmed
}
