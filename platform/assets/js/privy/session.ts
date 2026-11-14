// The browser's half of the sign-in session, as ash-template's auth_lazy.ts:
// the CSRF bootstrap at /auth/csrf, the three lifecycle refusals and their one
// recovery, the hold on the page's live connection while the cookie it would
// connect under changes, sign-in, sign-out, retiring a refused cookie, and the
// bounded sign-in failure report (`PatchbayWeb.PrivySessionController`).

const SESSION_PATH = "/auth/privy/session"

export type SignInFailureDiagnostic =
  | "bridge_startup"
  | "flow_closed"
  | "invalid_message"
  | "provider_error"
  | "request_timeout"
  | "session_exchange"
  | "unable_to_sign"

export const sessionLifecycles = [
  "session_superseded",
  "session_reset_required",
  "account_switch_required",
] as const

export type SessionLifecycle = (typeof sessionLifecycles)[number]

export class SessionLifecycleError extends Error {
  readonly lifecycle: SessionLifecycle

  constructor(lifecycle: SessionLifecycle) {
    super("This browser session changed. Starting it again.")
    this.lifecycle = lifecycle
  }
}

/** A sign-in the server judged and refused, in its own words when it gave them. */
export class SessionRefusal extends Error {
  readonly words: string | null

  constructor(words: string | null) {
    super("Sign in was refused.")
    this.words = words
  }
}

type RefusalBody = {code?: unknown; message?: unknown; hint?: unknown}

async function refusalBody(response: Response): Promise<RefusalBody | null> {
  try {
    const {error} = (await response.json()) as {error?: RefusalBody}
    return error ?? null
  } catch {
    return null
  }
}

function lifecycleOf(response: Response, refusal: RefusalBody | null): SessionLifecycleError | null {
  const code = refusal?.code
  if (response.status !== 409 || !sessionLifecycles.includes(code as SessionLifecycle)) return null
  return new SessionLifecycleError(code as SessionLifecycle)
}

// A superseded, reset or switched lineage recovers from the cookie the winning
// response already left in this browser, in exactly one further attempt.
export async function recoverOnce<T>(attempt: () => Promise<T>): Promise<T> {
  try {
    return await attempt()
  } catch (error) {
    if (!(error instanceof SessionLifecycleError)) throw error
    return attempt()
  }
}

// The page's meta tag is the one place the browser's current CSRF token lives,
// so the live connection and every session request read the same value.
function csrfMeta(): HTMLMetaElement | null {
  return globalThis.document?.querySelector<HTMLMetaElement>("meta[name='csrf-token']") ?? null
}

export function browserCsrfToken(): string {
  return csrfMeta()?.content ?? ""
}

/**
 * The CSRF token for the cookie this browser now carries, adopted into the
 * page's meta tag. A browser with no sign-in lineage is given a fresh one; a
 * superseded or ended one is told which, as a `SessionLifecycleError`.
 */
export async function csrfToken(fetcher: typeof fetch = fetch, renewed: () => void = () => {}): Promise<string> {
  const response = await fetcher("/auth/csrf", {credentials: "same-origin"})

  try {
    const lifecycle = lifecycleOf(response, response.status === 409 ? await refusalBody(response) : null)
    if (lifecycle) throw lifecycle
    if (!response.ok) throw new Error("Unable to start a secure session change.")
    const body = (await response.json()) as {csrf_token?: unknown}
    if (typeof body.csrf_token !== "string" || body.csrf_token.length === 0) {
      throw new Error("Unable to start a secure session change.")
    }
    const meta = csrfMeta()
    if (meta) meta.content = body.csrf_token
    return body.csrf_token
  } catch (refusal) {
    // The browser took whatever cookie this response carried when its headers
    // landed, so only the body can say what that was. A 200 is a bootstrap that
    // rotated or an observation that wrote nothing, and only the token in it
    // adopts the result; a 409 is a revoked lineage that dropped, unless the
    // body says superseded. Any other status left the cookie alone.
    const wroteNothing = refusal instanceof SessionLifecycleError && refusal.lifecycle === "session_superseded"
    if ((response.ok || response.status === 409) && !wroteNothing) renewed()
    throw refusal
  }
}

// Every request from this tab that may change the session cookie runs after
// the one before it has settled, so two of them never race to set it.
let tail: Promise<unknown> = Promise.resolve()

function inTurn<T>(change: () => Promise<T>): Promise<T> {
  const attempt = tail.then(change)
  tail = attempt.catch(() => undefined)
  return attempt
}

let openRotations = 0
let unreadRenewal = false
let adopting: Promise<void> | null = null
let documentLeaving = false
const heldSockets = new Set<() => void>()

// True only while this tab is known to hold the CSRF state of the cookie it
// would connect under.
const csrfStateIsCurrent = () => openRotations === 0 && !unreadRenewal

// A document that has begun to leave is replaced by one rendered for the
// cookie its own request carries, so from `beforeunload` on a held connection
// stays held and reads nothing: a read here would write a newer cookie behind
// the new page's back.
export function holdAdoptionWhileLeaving(view: Pick<Window, "addEventListener"> = window): void {
  view.addEventListener("beforeunload", () => { documentLeaving = true }, {once: true})
}

/** The one entry point of Phoenix's socket that opens a transport. */
export type PinnedSocket = {transportConnect: () => void}

// `transportConnect` is reached by the page's first connection, every
// reconnect and the page's visibility recoveries, so refusing it there holds
// every connection that would send a token the cookie no longer backs. An open
// connection never reaches it and survives the change. A held one connects once
// this tab has read the state the cookie now carries.
export function holdSocketDuringCookieRotation(socket: PinnedSocket, fetcher: typeof fetch = fetch): void {
  const transportConnect = socket.transportConnect.bind(socket)
  let held = false

  heldSockets.add(() => {
    if (!held) return
    held = false
    transportConnect()
  })

  socket.transportConnect = () => {
    if (csrfStateIsCurrent()) return transportConnect()
    held = true
    if (openRotations === 0) adoptUnreadRenewal(fetcher).catch(() => undefined)
  }
}

// One read, shared by every connection waiting on it.
function adoptUnreadRenewal(fetcher: typeof fetch): Promise<void> {
  if (adopting) return adopting

  const attempt = inTurn(async () => {
    // A sign-in or sign-out ahead of this read may already have read what the
    // cookie carries, and a document already leaving reads nothing.
    if (!unreadRenewal || documentLeaving) return
    await csrfToken(fetcher)
    // A change that opened while this read was in flight answers for itself.
    if (openRotations > 0) return
    unreadRenewal = false
    heldSockets.forEach(release => release())
  })

  adopting = attempt
  const settled = () => { if (adopting === attempt) adopting = null }
  void attempt.then(settled, settled)
  return attempt
}

// The interval between a response that rotated or dropped the cookie and this
// tab reading the CSRF state that cookie now carries. No connection opens
// inside it, because the token it would send belongs to the retired session.
// Callers call `renewed` for exactly the answers that write a session; one that
// fails after such an answer stays closed until a later read.
async function acrossCookieRotation<T>(rotation: (renewed: () => void) => Promise<T>): Promise<T> {
  openRotations += 1

  try {
    const adopted = await rotation(() => { unreadRenewal = true })
    if (openRotations === 1) unreadRenewal = false
    return adopted
  } finally {
    openRotations -= 1
    if (csrfStateIsCurrent()) heldSockets.forEach(release => release())
  }
}

/**
 * Signs this browser in with Privy's two tokens. Resolves once the session is
 * written and its token adopted; rejects with a `SessionRefusal` when the
 * server refused the sign-in, or any other error when it could not be asked.
 */
export function createLocalSession(
  pair: {access: string; identity: string},
  fetcher: typeof fetch = fetch,
): Promise<void> {
  return inTurn(() =>
    acrossCookieRotation(renewed =>
      recoverOnce(async () => {
        const csrf = await csrfToken(fetcher, renewed)
        const response = await fetcher(SESSION_PATH, {
          method: "POST",
          credentials: "same-origin",
          headers: {
            accept: "application/json",
            authorization: `Bearer ${pair.access}`,
            "privy-id-token": pair.identity,
            "x-csrf-token": csrf,
          },
        })

        if (response.ok) {
          renewed()
          await csrfToken(fetcher)
          return
        }

        const refusal = await refusalBody(response)
        // A refused sign-in, a suspended account, an account switch and an ended
        // lineage each leave a different cookie; only a superseded claim writes
        // none.
        const code = refusal?.code
        if (code === "unauthorized" || code === "suspended" || code === "session_reset_required" ||
            code === "account_switch_required") {
          renewed()
        }
        const lifecycle = lifecycleOf(response, refusal)
        if (lifecycle) throw lifecycle
        throw new SessionRefusal(refusalWords(refusal))
      }),
    ),
  )
}

// A refusal's own words and what to do, as the server wrote them.
function refusalWords(refusal: RefusalBody | null): string | null {
  return typeof refusal?.message === "string" && typeof refusal?.hint === "string"
    ? `${refusal.message} ${refusal.hint}`
    : null
}

// Sign out leads with the token this page holds, which is what lets a stale
// lineage still revoke itself. Only a CSRF refusal means another tab rotated the
// shared cookie underneath this one; that alone earns a single adoption and one
// more attempt at an idempotent delete. Every other failure is final.
export function clearLocalSession(fetcher: typeof fetch = fetch): Promise<void> {
  return inTurn(async () => {
    if (!(await deleteLocalSession(fetcher, browserCsrfToken()))) return
    if (await deleteLocalSession(fetcher, await csrfToken(fetcher))) {
      throw new Error("Sign out could not be completed.")
    }
  })
}

// True when the delete was refused for its CSRF token.
async function deleteLocalSession(fetcher: typeof fetch, csrf: string): Promise<boolean> {
  const response = await fetcher(SESSION_PATH, {
    method: "DELETE",
    credentials: "same-origin",
    headers: {"x-csrf-token": csrf},
  })
  if (response.ok) return false
  if (response.status === 403) return true
  throw new Error("Sign out could not be completed.")
}

// A page rendered for a cookie the server refuses says so, because no ordinary
// answer may replace that cookie. `/auth/csrf` retires a revoked or ended claim
// and replaces a malformed one. A superseded claim is left alone there in case
// the winning cookie is still on its way, so it gets a second look; one that is
// still superseded never received that cookie, and only sign out accepts it.
// The live connection is held throughout, so it connects under the result.
export function retireRefusedSession(documentRoot: Document = document, fetcher: typeof fetch = fetch): Promise<void> {
  if (!documentRoot.querySelector("meta[name='session-refused']")) return Promise.resolve()

  const stillSuperseded = async (renewed: () => void) => {
    try {
      await csrfToken(fetcher, renewed)
      return false
    } catch (refusal) {
      if (!(refusal instanceof SessionLifecycleError)) throw refusal
      return refusal.lifecycle === "session_superseded"
    }
  }

  return acrossCookieRotation(async renewed => {
    if (!(await inTurn(() => stillSuperseded(renewed)))) return
    if (!(await inTurn(() => stillSuperseded(renewed)))) return
    await clearLocalSession(fetcher)
  }).catch(() => undefined)
}

/**
 * Tells the server why a sign-in failed in this browser, by one of the fixed
 * reasons and nothing else. Sent only under a token this tab knows is current.
 */
export function reportSignInFailure(failure: SignInFailureDiagnostic, fetcher: typeof fetch = fetch): void {
  void (async () => {
    if (!csrfStateIsCurrent()) await adoptUnreadRenewal(fetcher)
    if (!csrfStateIsCurrent()) return

    const csrf = browserCsrfToken()
    if (!csrf) return

    await fetcher("/auth/privy/failure", {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      keepalive: true,
      headers: {"content-type": "application/json", "x-csrf-token": csrf},
      body: JSON.stringify({reason: failure}),
    })
  })().catch(() => undefined)
}
