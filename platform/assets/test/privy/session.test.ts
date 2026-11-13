import assert from "node:assert/strict"
import {test} from "node:test"

import {
  clearLocalSession,
  createLocalSession,
  holdSocketDuringCookieRotation,
  reportSignInFailure,
  retireRefusedSession,
  SessionLifecycleError,
  SessionRefusal,
} from "../../js/privy/session.ts"

// The browser's half of the sign-in session against a scripted server: the
// CSRF bootstrap before every sign-in, one recovery from an ended lineage, the
// live connection held while the cookie it would connect under changes, the
// sign-out retry and the retiring of a refused cookie.
type Sent = {method: string; path: string; headers: Record<string, string>; body?: string; keepalive?: boolean}
type Answer = {status: number; body?: unknown}

const meta = {content: "page-token"}
let refusedCookie = false
const page = {
  querySelector: (selector: string) => {
    if (selector === "meta[name='csrf-token']") return meta
    if (selector === "meta[name='session-refused']") return refusedCookie ? {} : null
    return null
  },
} as unknown as Document
Object.assign(globalThis, {document: page})

let script: Answer[] = []
let sent: Sent[] = []

const fetch = (async (path: string, init: RequestInit = {}) => {
  sent.push({
    method: init.method ?? "GET",
    path,
    headers: (init.headers ?? {}) as Record<string, string>,
    body: init.body as string | undefined,
    keepalive: init.keepalive,
  })
  const answer = script.shift()
  if (!answer) throw new Error(`Nothing scripted for ${init.method ?? "GET"} ${path}`)
  return new Response(answer.status === 204 ? null : JSON.stringify(answer.body ?? {}), {status: answer.status})
}) as unknown as typeof globalThis.fetch

function serve(...answers: Answer[]) {
  script = answers
  sent = []
}

const requests = () => sent.map(({method, path}) => `${method} ${path}`)
const token = (csrf_token: string): Answer => ({status: 200, body: {csrf_token}})
const refusal = (status: number, code: string): Answer => ({
  status,
  body: {error: {code, message: "Refused.", hint: "Sign in again."}},
})
const signedIn: Answer = {status: 200, body: {authenticated: true}}
const pair = {access: "access-token", identity: "identity-token"}

// The page's one live connection, installed before anything changes the cookie.
let connects = 0
const socket = {transportConnect: () => { connects += 1 }}
holdSocketDuringCookieRotation(socket, fetch)

async function until(done: () => boolean) {
  for (let turn = 0; turn < 100 && !done(); turn += 1) await new Promise(resolve => setImmediate(resolve))
  assert.ok(done())
}

test("a sign-in fetches its token, sends the pair under it, and adopts the token of the session it wrote", async () => {
  serve(token("bootstrap"), signedIn, token("signed-in"))

  await createLocalSession(pair, fetch)

  assert.deepEqual(requests(), ["GET /auth/csrf", "POST /auth/privy/session", "GET /auth/csrf"])
  assert.equal(sent[1].headers.authorization, "Bearer access-token")
  assert.equal(sent[1].headers["privy-id-token"], "identity-token")
  assert.equal(sent[1].headers["x-csrf-token"], "bootstrap")
  assert.equal(meta.content, "signed-in")
})

test("a lineage the server ended is started again once, under the cookie its answer left", async () => {
  serve(token("old"), refusal(409, "session_reset_required"), token("fresh"), signedIn, token("signed-in"))

  await createLocalSession(pair, fetch)

  const posts = sent.filter(({method}) => method === "POST")
  assert.deepEqual(posts.map(post => post.headers["x-csrf-token"]), ["old", "fresh"])
  assert.equal(meta.content, "signed-in")
})

test("a refused sign-in carries the server's words, and the live connection waits for the token of the cookie it left", async () => {
  serve(token("before"), refusal(401, "unauthorized"))

  const failure = await createLocalSession(pair, fetch).catch(error => error)

  assert.ok(failure instanceof SessionRefusal)
  assert.equal(failure.words, "Refused. Sign in again.")

  // The server dropped the lineage's connections. The reconnect waits for one
  // read of the token the new cookie backs, then goes ahead under it.
  serve(token("after"))
  const before = connects
  socket.transportConnect()
  assert.equal(connects, before)

  await until(() => connects === before + 1)
  assert.deepEqual(requests(), ["GET /auth/csrf"])
  assert.equal(meta.content, "after")
})

test("a claim superseded from another tab writes nothing: no sign-in is sent and no connection waits", async () => {
  serve(refusal(409, "session_superseded"), refusal(409, "session_superseded"))

  const failure = await createLocalSession(pair, fetch).catch(error => error)

  assert.ok(failure instanceof SessionLifecycleError)
  assert.equal(failure.lifecycle, "session_superseded")
  assert.deepEqual(requests(), ["GET /auth/csrf", "GET /auth/csrf"])

  const before = connects
  socket.transportConnect()
  assert.equal(connects, before + 1)
})

test("sign out sends the page's token, and after a CSRF refusal tries once more under a fresh one", async () => {
  meta.content = "stale"
  serve({status: 403}, token("current"), {status: 200, body: {ok: true}})

  await clearLocalSession(fetch)

  assert.deepEqual(requests(), ["DELETE /auth/privy/session", "GET /auth/csrf", "DELETE /auth/privy/session"])
  assert.deepEqual(sent.filter(({method}) => method === "DELETE").map(one => one.headers["x-csrf-token"]), ["stale", "current"])

  serve({status: 403}, token("again"), {status: 403})
  await assert.rejects(clearLocalSession(fetch))
  assert.equal(sent.length, 3)
})

test("a page drawn for a refused cookie retires it, and signs out a claim that stays superseded", async () => {
  refusedCookie = false
  serve()
  await retireRefusedSession(page, fetch)
  assert.deepEqual(requests(), [])

  refusedCookie = true
  serve(token("retired"))
  await retireRefusedSession(page, fetch)
  assert.deepEqual(requests(), ["GET /auth/csrf"])
  assert.equal(meta.content, "retired")

  serve(refusal(409, "session_superseded"), refusal(409, "session_superseded"), {status: 200, body: {ok: true}})
  await retireRefusedSession(page, fetch)
  assert.deepEqual(requests(), ["GET /auth/csrf", "GET /auth/csrf", "DELETE /auth/privy/session"])
})

test("a sign-in failure is reported by its reason alone, under the page's token", async () => {
  meta.content = "current"
  serve({status: 204})

  reportSignInFailure("flow_closed", fetch)

  await until(() => sent.length === 1)
  assert.deepEqual(requests(), ["POST /auth/privy/failure"])
  assert.equal(sent[0].body, JSON.stringify({reason: "flow_closed"}))
  assert.equal(sent[0].headers["x-csrf-token"], "current")
  assert.equal(sent[0].keepalive, true)
})
