import assert from "node:assert/strict"
import {test} from "node:test"

import {installAccountControl, requestAccountAction} from "../../js/privy/account.ts"

// The account control's sign-in, with the bridge and the session address faked:
// a refusal says why under the header, a sign-in with no wallet sends nothing,
// and a page Privy brought back from Google finishes that sign-in by itself.
type Status = {textContent: string; hidden: boolean}

function page(search = "", signedOut = true) {
  const status: Status = {textContent: "", hidden: true}
  const doc = {
    location: {search},
    addEventListener: () => {},
    querySelector: (selector: string) => {
      if (selector === 'meta[name="privy-app-id"]') return {getAttribute: () => "app-1"}
      if (selector === "#account-auth-status") return status
      if (selector === "[data-account-target='sign-in']") return signedOut ? {} : null
      return null
    },
  }
  return {doc: doc as unknown as Document, status}
}

function session(answer: {status: number; body?: unknown}) {
  const sent: {method: string; headers: Record<string, string>}[] = []
  const fetch = (async (_path: string, init: {method: string; headers: Record<string, string>}) => {
    sent.push(init)
    return new Response(JSON.stringify(answer.body ?? {}), {status: answer.status})
  }) as unknown as typeof globalThis.fetch
  return {sent, fetch}
}

const proof = {ok: true as const, access: "access-token", identity: "identity-token"}
const bridge = (signIn: unknown, finishRedirectSignIn: unknown = signIn) => async () => ({
  signIn: async () => signIn,
  finishRedirectSignIn: async () => finishRedirectSignIn,
  signOut: async () => {},
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

test("a sign-in Patchbay refuses shows the refusal's words and stays on the page", async () => {
  const {doc, status} = page()
  const {sent, fetch} = session({status: 422, body: {error: {code: "no_wallet", message: "Your account has no wallet yet.", hint: "Sign in again to get one."}}})
  let reloaded = false
  await requestAccountAction("sign-in", doc, {fetch, loadBridge: bridge(proof), location: {reload: () => { reloaded = true }}})
  assert.equal(sent.length, 1)
  assert.equal(sent[0].headers.authorization, "Bearer access-token")
  assert.equal(sent[0].headers["privy-id-token"], "identity-token")
  assert.equal(reloaded, false)
  assert.equal(status.hidden, false)
  assert.equal(status.textContent, "Your account has no wallet yet. Sign in again to get one.")
})

test("a sign-in that goes through reloads, and a closed window says nothing", async () => {
  const signedIn = page()
  const ok = session({status: 200})
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
  const {sent, fetch} = session({status: 200})
  const reloaded = new Promise<void>(resolve => {
    installAccountControl({document: doc, fetch, loadBridge: bridge({ok: false, reason: "not this one"}, proof), location: {reload: resolve}})
  })
  await reloaded
  assert.equal(sent.length, 1)
  assert.equal(sent[0].method, "POST")
  assert.equal(sent[0].headers["privy-id-token"], "identity-token")
})

test("a page without Privy's return, or one already signed in, starts nothing on load", async () => {
  for (const {doc} of [page(""), page("?privy_oauth_code=abc", false)]) {
    let loaded = false
    installAccountControl({document: doc, fetch: session({status: 200}).fetch, loadBridge: async () => { loaded = true; return null }})
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(loaded, false)
  }
})
