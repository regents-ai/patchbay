import assert from "node:assert/strict"
import {test} from "node:test"

import {installAccountControl, requestAccountAction} from "../../js/privy/account.ts"

// The account control's sign-in and sign-out, with the bridge and the session
// endpoints faked: a refusal says why under the header, a sign-in with no
// wallet sends nothing, and a page Privy brought back from Google finishes that
// sign-in by itself.
type Status = {textContent: string; hidden: boolean}

function page(search = "", signedOut = true, choices: string | null = null) {
  const status: Status = {textContent: "", hidden: true}
  const doc = {
    location: {search},
    addEventListener: () => {},
    querySelector: (selector: string) => {
      if (selector === 'meta[name="privy-app-id"]') return {getAttribute: () => "app-1"}
      if (selector === 'meta[name="privy-sign-in"]') return choices === null ? null : {getAttribute: () => choices}
      if (selector === "#account-auth-status") return status
      if (selector === "[data-account-target='sign-in']") return signedOut ? {} : null
      return null
    },
  }
  return {doc: doc as unknown as Document, status}
}

// The CSRF bootstrap answers a fresh token each time it is asked; the session
// address answers `answer`.
function session(answer: {status: number; body?: unknown}) {
  const sent: {method: string; path: string; headers: Record<string, string>}[] = []
  let tokens = 0
  const fetch = (async (path: string, init: {method?: string; headers?: Record<string, string>} = {}) => {
    sent.push({method: init.method ?? "GET", path, headers: init.headers ?? {}})
    if (path === "/auth/csrf") return Response.json({csrf_token: `token-${(tokens += 1)}`})
    return new Response(JSON.stringify(answer.body ?? {}), {status: answer.status})
  }) as unknown as typeof globalThis.fetch
  return {sent, fetch}
}

const proof = {ok: true as const, access: "access-token", identity: "identity-token"}
const bridge = (signIn: unknown, finishRedirectSignIn: unknown = signIn, signedOut: string[] = []) => async () => ({
  signIn: async () => signIn,
  finishRedirectSignIn: async () => finishRedirectSignIn,
  signOut: async (appId: string) => { signedOut.push(appId) },
}) as never

test("a sign-in whose wallet never appears sends nothing and says so", async () => {
  const {doc, status} = page()
  const {sent, fetch} = session({status: 200})
  let reloaded = false
  await requestAccountAction("sign-in", doc, {fetch, loadBridge: bridge({ok: false, reason: "no_wallet"}), location: {reload: () => { reloaded = true }}})
  assert.deepEqual(sent, [])
  assert.equal(reloaded, false)
  assert.equal(status.hidden, false)
  assert.equal(status.textContent, "Your account has no wallet yet. Sign in again to get one.")
})

test("at the open address a sign-in whose wallet never appears says the account is not ready", async () => {
  const {doc, status} = page("", true, "email")
  const {sent, fetch} = session({status: 200})
  await requestAccountAction("sign-in", doc, {fetch, loadBridge: bridge({ok: false, reason: "no_wallet"})})
  assert.deepEqual(sent, [])
  assert.equal(status.textContent, "Your account is not ready yet. Sign in again to finish.")
})

test("a sign-in Patchbay refuses is sent under a fresh token, shows the refusal's words and stays on the page", async () => {
  const {doc, status} = page()
  const {sent, fetch} = session({status: 429, body: {error: {code: "rate_limited", message: "Too many new sign-ins came from this address.", hint: "Wait, then try again."}}})
  let reloaded = false
  await requestAccountAction("sign-in", doc, {fetch, loadBridge: bridge(proof), location: {reload: () => { reloaded = true }}})
  assert.deepEqual(sent.map(({method, path}) => `${method} ${path}`), ["GET /auth/csrf", "POST /auth/privy/session"])
  assert.equal(sent[1].headers.authorization, "Bearer access-token")
  assert.equal(sent[1].headers["privy-id-token"], "identity-token")
  assert.equal(sent[1].headers["x-csrf-token"], "token-1")
  assert.equal(reloaded, false)
  assert.equal(status.hidden, false)
  assert.equal(status.textContent, "Too many new sign-ins came from this address. Wait, then try again.")
})

test("a sign-in that goes through reloads, and a closed window says nothing", async () => {
  const signedIn = page()
  const ok = session({status: 200, body: {authenticated: true}})
  let reloaded = false
  await requestAccountAction("sign-in", signedIn.doc, {fetch: ok.fetch, loadBridge: bridge(proof), location: {reload: () => { reloaded = true }}})
  assert.equal(reloaded, true)
  assert.equal(signedIn.status.hidden, true)

  const closed = page()
  const none = session({status: 200})
  await requestAccountAction("sign-in", closed.doc, {fetch: none.fetch, loadBridge: bridge({ok: false, reason: "closed"})})
  assert.deepEqual(none.sent, [])
  assert.equal(closed.status.hidden, true)
})

test("a signed-out page Privy brought back from Google finishes that sign-in through the session address", async () => {
  const {doc} = page("?privy_oauth_code=abc&privy_oauth_state=def")
  const {sent, fetch} = session({status: 200, body: {authenticated: true}})
  const reloaded = new Promise<void>(resolve => {
    installAccountControl({document: doc, fetch, loadBridge: bridge({ok: false, reason: "not this one"}, proof), location: {reload: resolve}})
  })
  await reloaded
  const post = sent.find(({method}) => method === "POST")!
  assert.equal(post.path, "/auth/privy/session")
  assert.equal(post.headers["privy-id-token"], "identity-token")
})

test("sign out ends the Patchbay session first, then Privy's, then reloads", async () => {
  const {doc} = page("", false)
  const {sent, fetch} = session({status: 200, body: {ok: true}})
  const signedOut: string[] = []
  let reloaded = false
  await requestAccountAction("sign-out", doc, {fetch, loadBridge: bridge(proof, proof, signedOut), location: {reload: () => { reloaded = true }}})
  assert.deepEqual(sent.map(({method, path}) => `${method} ${path}`), ["DELETE /auth/privy/session"])
  assert.deepEqual(signedOut, ["app-1"])
  assert.equal(reloaded, true)
})

test("a page without Privy's return, or one already signed in, starts nothing on load", async () => {
  for (const {doc} of [page(""), page("?privy_oauth_code=abc", false)]) {
    let loaded = false
    installAccountControl({document: doc, fetch: session({status: 200}).fetch, loadBridge: async () => { loaded = true; return null }})
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(loaded, false)
  }
})
