import type * as PrivyBridge from "../privy_bridge.tsx"
import {returnedFromOAuth} from "./sign_in.ts"
import type {Proof, Refusal} from "./sign_in.ts"

const SESSION_PATH = "/auth/privy/session"

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
  loadBridge?: (doc: MetaDocument) => Promise<Pick<PrivyBridgeModule, "signIn" | "finishRedirectSignIn" | "signOut"> | null>
}

// Patchbay refuses a sign-in whose Privy account has no wallet; the page says so
// in the server's words when the account's wallet never appears here either.
const NO_WALLET = "Your account has no wallet yet. Sign in again to get one."

/**
 * Wires every `data-account-target` control on the page to Privy: the account
 * strip in the root layout, and the Account page's own Sign in.
 *
 * Both are drawn from the signed session, so this only has to answer two
 * clicks, and one page load: Privy brings a Google or other redirect sign-in
 * back to the page it started on with `?privy_oauth_code=`, and it finishes only
 * once Privy runs there, so a signed-out page Privy returned to starts it at once
 * and finishes that sign-in (as ash-template's auth_lazy.ts). Nothing else here
 * reconciles state on load: a Privy that is still waking up says nothing about
 * whether this browser is signed in to Patchbay, and the page already knows the
 * answer to that.
 */
export function installAccountControl(options: AccountOptions = {}) {
  const doc = options.document ?? globalThis.document
  if (!doc) return

  let running = false

  doc.addEventListener("click", async event => {
    const button = (event.target as Element).closest?.<HTMLButtonElement>("[data-account-target]")
    if (!button || running) return

    running = true
    button.disabled = true

    try {
      await requestAccountAction(button.dataset.accountTarget!, doc, options)
    } finally {
      running = false
      button.disabled = false
    }
  })

  if (returnedFromOAuth(doc.location?.search ?? "") && doc.querySelector("[data-account-target='sign-in']")) {
    void requestAccountAction("redirect-sign-in", doc, options)
  }
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

// A page that signed in or out reloads, and one that did not stays as it was.
// A sign-in Patchbay refused, or one whose wallet never appeared, says why under
// the header's account control; any other that did not go through says nothing.
async function performAccountAction(action: string, doc: Document, options: AccountOptions = {}): Promise<void> {
  const appId = privyAppId(doc)
  if (!appId) return

  const bridge = await (options.loadBridge ?? loadPrivyBridge)(doc)
  if (!bridge) return

  if (action === "sign-in") return signIn(bridge.signIn(appId), doc, options)
  if (action === "redirect-sign-in") return signIn(bridge.finishRedirectSignIn(appId), doc, options)
  return signOut(bridge, appId, options)
}

async function signIn(proving: Promise<Proof | Refusal>, doc: Document, options: AccountOptions): Promise<void> {
  showStatus(doc, null)
  const proof = await proving
  if (!proof.ok) {
    if (proof.reason === "no_wallet") showStatus(doc, NO_WALLET)
    return
  }

  const response = await send(options, "POST", {
    authorization: `Bearer ${proof.access}`,
    "privy-id-token": proof.identity,
  })

  // The page is drawn from the session, so the session is what a reload reads.
  if (response?.ok) return reload(options)
  showStatus(doc, await refusalWords(response))
}

// The Patchbay session goes first, because that is the one this page is drawn
// from. Ending the Privy session behind it is cleanup: if it fails, the visitor
// is still signed out of Patchbay.
async function signOut(bridge: Pick<PrivyBridgeModule, "signOut">, appId: string, options: AccountOptions): Promise<void> {
  if (!(await send(options, "DELETE", {}))?.ok) return

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

// The session endpoint's answer, or null when it could not be asked.
async function send(options: AccountOptions, method: string, headers: Record<string, string>): Promise<Response | null> {
  const fetchImpl = options.fetch ?? globalThis.fetch
  if (typeof fetchImpl !== "function") return null

  try {
    return await fetchImpl(SESSION_PATH, {
      method,
      credentials: "same-origin",
      headers: {accept: "application/json", "x-csrf-token": options.csrfToken ?? "", ...headers},
    })
  } catch {
    return null
  }
}

// A refusal's own words and what to do, as the session endpoint wrote them, or
// nothing when it gave none.
async function refusalWords(response: Response | null): Promise<string | null> {
  try {
    const {error} = await response!.json()
    return typeof error?.message === "string" && typeof error?.hint === "string" ? `${error.message} ${error.hint}` : null
  } catch {
    return null
  }
}

// The note under the header's account control, or none.
function showStatus(doc: Document, words: string | null) {
  const status = doc.querySelector<HTMLElement>("#account-auth-status")
  if (!status) return
  status.textContent = words ?? ""
  status.hidden = words === null
}

function reload(options: AccountOptions) {
  const location = options.location ?? globalThis.location
  location?.reload?.()
}

function metaContent(doc: MetaDocument | undefined, name: string): string | null {
  const content = doc?.querySelector?.(`meta[name="${name}"]`)?.getAttribute("content")
  const trimmed = typeof content === "string" ? content.trim() : ""
  return trimmed === "" ? null : trimmed
}
