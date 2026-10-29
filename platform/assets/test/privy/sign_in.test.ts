import assert from "node:assert/strict"
import {mock, test} from "node:test"

import {handOver, returnedFromOAuth, stateWaiters, TOKEN_TIMEOUT_MS} from "../../js/privy/sign_in.ts"
import type {SignInState} from "../../js/privy/sign_in.ts"

// The order a sign-in hands Privy's tokens over in, against Privy's state as its
// hooks publish it: nothing until the account links a wallet, the identity token
// before the access token, and no_wallet with nothing read after 15 seconds.
const email = {type: "email", address: "made@example.com"}
const wallet = {type: "wallet", chainType: "ethereum", address: "0x" + "7".repeat(40)}

function privy(reads: string[]) {
  const waiters = stateWaiters<SignInState>()
  const state = (...linkedAccounts: object[]): SignInState => ({
    authenticated: true,
    user: {linkedAccounts} as unknown as SignInState["user"],
    getAccessToken: async () => { reads.push("access"); return "access-token" },
  })
  const identity = async () => { reads.push("identity"); return "identity-token" }
  return {waiters, state, identity}
}

test("an email sign-in waits for the wallet Privy makes, then reads the identity token before the access token", async () => {
  const reads: string[] = []
  const {waiters, state, identity} = privy(reads)
  waiters.publish(state(email))

  const proof = handOver(waiters.waitFor, identity)
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(reads, [], "nothing is read before the wallet")

  waiters.publish(state(email, wallet))
  assert.deepEqual(await proof, {ok: true, access: "access-token", identity: "identity-token"})
  assert.deepEqual(reads, ["identity", "access"])
})

test("with no wallet after 15 seconds, the answer is no_wallet and no token is read", async () => {
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    const reads: string[] = []
    const {waiters, state, identity} = privy(reads)
    waiters.publish(state(email))

    const proof = handOver(waiters.waitFor, identity)
    mock.timers.tick(TOKEN_TIMEOUT_MS - 1)
    waiters.publish(state(email))
    mock.timers.tick(1)

    assert.deepEqual(await proof, {ok: false, reason: "no_wallet"})
    assert.deepEqual(reads, [])
    assert.equal(TOKEN_TIMEOUT_MS, 15_000)
  } finally {
    mock.timers.reset()
  }
})

test("an empty token is never handed over", async () => {
  const {waiters, state} = privy([])
  waiters.publish(state(wallet))
  assert.deepEqual(await handOver(waiters.waitFor, async () => " "), {ok: false, reason: "no_identity_token"})
  const noAccess = {...state(wallet), getAccessToken: async () => null}
  waiters.publish(noAccess)
  assert.deepEqual(await handOver(waiters.waitFor, async () => "identity-token"), {ok: false, reason: "no_access_token"})
})

test("a page Privy brought back from Google carries privy_oauth_code", () => {
  assert.equal(returnedFromOAuth("?privy_oauth_code=abc&privy_oauth_state=def"), true)
  assert.equal(returnedFromOAuth("?q=privy_oauth_code"), false)
  assert.equal(returnedFromOAuth(""), false)
})
