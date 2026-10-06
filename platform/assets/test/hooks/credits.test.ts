import assert from "node:assert/strict"
import {test} from "node:test"

import {current, press, pressWallet} from "../../js/hooks/credits.ts"
import type {Review} from "../../js/hooks/credits.ts"
import type {MetaDocument} from "../../js/privy/account.ts"
import type {SelectedWallet} from "../../js/wallet_actions/send_step.ts"

const SIGNER = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
const OTHER = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const HASH = `0x${"ab".repeat(32)}`

const review: Review = {
  id: "review-1",
  component_id: "pb-credits-panel",
  signer: SIGNER,
  chain: {chain_id: 8453, name: "Base", rpc_url: "https://mainnet.base.org"},
  steps: [{kind: "transaction", step: "buy", to: OTHER, data: "0x1234", value: "0x0"}],
  inputs: {amount: "10", chain: "base"},
}

// A wallet answering by method name, on `chain` as `account`, recording every request.
function wallet({chain = "0x2105", account = SIGNER, send}: {chain?: string; account?: string; send?: () => unknown} = {}) {
  const asked: string[] = []
  const selected: SelectedWallet = {
    address: SIGNER,
    provider: {
      request: async ({method}) => {
        asked.push(method)
        if (method === "eth_chainId") return chain
        if (method === "eth_accounts") return [account]
        if (method === "wallet_switchEthereumChain") throw Object.assign(new Error("no"), {code: 4001})
        if (method === "eth_sendTransaction") return send ? send() : HASH
        throw new Error(`unexpected ${method}`)
      },
    },
  }
  return {selected, asked}
}

function pushes() {
  const pushed: Array<[string, unknown]> = []
  return {pushed, push: (event: string, payload: unknown) => void pushed.push([event, payload])}
}

test("two presses in a row both reach the wallet's send", async () => {
  const {selected, asked} = wallet()
  const {pushed, push} = pushes()
  await Promise.all([press(review, "buy", selected, push), press(review, "buy", selected, push)])
  assert.equal(asked.filter(method => method === "eth_sendTransaction").length, 2)
  assert.deepEqual(pushed, [
    ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: HASH}],
    ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: HASH}],
  ])
})

test("a declined send is reported as declined", async () => {
  const {selected} = wallet({send: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
  const {pushed, push} = pushes()
  await press(review, "buy", selected, push)
  assert.deepEqual(pushed, [["step_failed", {step: "buy", reason: "wallet_declined"}]])
})

test("nothing is sent from the wrong account or on the wrong chain", async () => {
  for (const [options, reason] of [[{account: OTHER}, "wallet_unavailable"], [{chain: "0x1"}, "network_mismatch"]] as const) {
    const {selected, asked} = wallet(options)
    const {pushed, push} = pushes()
    await press(review, "buy", selected, push)
    assert.ok(!asked.includes("eth_sendTransaction"))
    assert.deepEqual(pushed, [["step_failed", {step: "buy", reason}]])
  }
})

test("a review is sent as it stands only for its own wallet and the form on screen", () => {
  const {selected} = wallet()
  assert.equal(current(review, selected, {amount: "10", chain: "base"}), true)
  assert.equal(current(review, selected, {amount: "11", chain: "base"}), false)
  assert.equal(current(review, {...selected, address: OTHER}, {amount: "10", chain: "base"}), false)
  assert.equal(current(undefined, selected, {amount: "10", chain: "base"}), false)
})

test("a press with no Privy to reach, or no sign-in there, says which", async () => {
  const page = (appId: string | null): MetaDocument => ({
    querySelector: selector =>
      selector === 'meta[name="privy-app-id"]' && appId !== null ? {getAttribute: () => appId} : null,
  })
  const bridge = (answer: {ok: false; reason: string}) => async () => ({activeWallet: async () => answer})

  assert.deepEqual(await pressWallet(page(null), async () => assert.fail("loaded")), {ok: false, reason: "wallet_unreachable"})
  assert.deepEqual(await pressWallet(page("app-1"), async () => null), {ok: false, reason: "wallet_unreachable"})
  assert.deepEqual(await pressWallet(page("app-1"), bridge({ok: false, reason: "unready"})), {ok: false, reason: "wallet_unreachable"})
  assert.deepEqual(await pressWallet(page("app-1"), bridge({ok: false, reason: "signed_out"})), {ok: false, reason: "privy_signed_out"})
  assert.deepEqual(await pressWallet(page("app-1"), bridge({ok: false, reason: "wallet_unavailable"})), {ok: false, reason: "wallet_unavailable"})
})
