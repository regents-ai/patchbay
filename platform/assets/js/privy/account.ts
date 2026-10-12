import type * as PrivyBridge from "../privy_bridge.tsx"

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
}

/**
 * Wires every `data-pb-account` control on the page to Privy: the account
 * strip in the root layout, and the Account page's own Sign in.
 *
 * Both are drawn from the signed session, so this only has to answer two
 * clicks. Nothing here reconciles state on load: a Privy that is still waking
 * up says nothing about whether this browser is signed in to Patchbay, and the
 * page already knows the answer to that.
 */
export function installAccountControl(options: AccountOptions = {}) {
  const doc = options.document ?? globalThis.document
  if (!doc) return

  let running = false

  doc.addEventListener("click", async event => {
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

// Signing in and out says nothing, even when it does not go through: a page
// that signed in or out reloads, and one that did not stays as it was.
async function performAccountAction(action: string, doc: Document, options: AccountOptions = {}): Promise<void> {
  const appId = privyAppId(doc)
  if (!appId) return

  const bridge = await loadPrivyBridge(doc)
  if (!bridge) return

  if (action === "sign-in") return signIn(bridge, appId, options)
  return signOut(bridge, appId, options)
}

async function signIn(bridge: PrivyBridgeModule, appId: string, options: AccountOptions): Promise<void> {
  const proof = await bridge.signIn(appId)
  if (!proof.ok) return

  const signedIn = await call(options, "POST", {
    authorization: `Bearer ${proof.access}`,
    "privy-id-token": proof.identity,
  })

  // The page is drawn from the session, so the session is what a reload reads.
  if (signedIn) reload(options)
}

// The Patchbay session goes first, because that is the one this page is drawn
// from. Ending the Privy session behind it is cleanup: if it fails, the visitor
// is still signed out of Patchbay.
async function signOut(bridge: PrivyBridgeModule, appId: string, options: AccountOptions): Promise<void> {
  if (!(await call(options, "DELETE", {}))) return

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

// Whether the session endpoint took the request.
async function call(options: AccountOptions, method: string, headers: Record<string, string>): Promise<boolean> {
  const fetchImpl = options.fetch ?? globalThis.fetch
  if (typeof fetchImpl !== "function") return false

  try {
    const response = await fetchImpl(SESSION_PATH, {
      method,
      credentials: "same-origin",
      headers: {accept: "application/json", "x-csrf-token": options.csrfToken ?? "", ...headers},
    })

    return response.ok === true
  } catch {
    return false
  }
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
