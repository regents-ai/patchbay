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
  unreachable: "Patchbay could not be reached. Check your connection and try again.",
  refused_locally: "That sign-in could not be verified.",
  sign_out_failed: "Signing out did not go through. Try again.",
}

/**
 * Wires the account strip in the root layout to Privy.
 *
 * The strip is the same on every page and is drawn from the signed session, so
 * this only has to answer two clicks. Nothing here reconciles state on load: a
 * Privy that is still waking up says nothing about whether this browser is
 * signed in to Patchbay, and the page already knows the answer to that.
 *
 * @param {{document?: Document, fetch?: typeof globalThis.fetch, csrfToken?: string}} [options]
 */
export function installAccountControl(options = {}) {
  const doc = options.document ?? globalThis.document
  const strip = doc?.getElementById?.("pb-account")
  if (!strip) return

  let running = false

  strip.addEventListener("click", async event => {
    const button = event.target.closest?.("[data-pb-account]")
    if (!button || running) return

    running = true
    button.disabled = true

    try {
      await act(button.dataset.pbAccount, doc, options)
    } finally {
      running = false
      button.disabled = false
    }
  })
}

async function act(action, doc, options) {
  const appId = metaContent(doc, "privy-app-id")
  const say = message => report(doc, message)

  if (!appId) return say(MESSAGES.unconfigured)

  const bridge = await load(doc)
  if (!bridge) return say(MESSAGES.unloadable)

  if (action === "sign-in") return signIn(bridge, appId, options, say)
  return signOut(bridge, appId, options, say)
}

async function signIn(bridge, appId, options, say) {
  say(MESSAGES.opening)

  const proof = await bridge.signIn(appId)
  if (!proof.ok) return say(MESSAGES[proof.reason] ?? MESSAGES.refused)

  say(MESSAGES.signing_in)

  const answer = await call(options, "POST", {
    authorization: `Bearer ${proof.access}`,
    "privy-id-token": proof.identity,
  })

  // The page is drawn from the session, so the session is what a reload reads.
  if (answer.ok) return reload(options)

  say(answer.body?.error ?? MESSAGES.refused_locally)
}

// The Patchbay session goes first, because that is the one this page is drawn
// from. Ending the Privy session behind it is cleanup: if it fails, the visitor
// is still signed out of Patchbay, and saying otherwise would be untrue.
async function signOut(bridge, appId, options, say) {
  say(MESSAGES.signing_out)

  const answer = await call(options, "DELETE", {})
  if (!answer.ok) return say(answer.body?.error ?? MESSAGES.sign_out_failed)

  try {
    await bridge.signOut(appId)
  } catch {
    // Cleanup only. The visitor is signed out either way.
  }

  reload(options)
}

async function load(doc) {
  const source = metaContent(doc, "privy-bridge-src")
  if (!source) return null

  try {
    return await import(source)
  } catch {
    return null
  }
}

async function call(options, method, headers) {
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
    return {ok: false, body: {error: MESSAGES.unreachable}}
  }
}

async function readBody(response) {
  try {
    return await response.json()
  } catch {
    return null
  }
}

function reload(options) {
  const location = options.location ?? globalThis.location
  location?.reload?.()
}

function report(doc, message) {
  const note = doc.getElementById("pb-account-note")
  if (note) note.textContent = message
}

function metaContent(doc, name) {
  const content = doc.querySelector?.(`meta[name="${name}"]`)?.getAttribute("content")
  const trimmed = typeof content === "string" ? content.trim() : ""
  return trimmed === "" ? null : trimmed
}
