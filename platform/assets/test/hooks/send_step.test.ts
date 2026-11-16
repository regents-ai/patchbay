import assert from "node:assert/strict"
import {test} from "node:test"

import {press, type Review} from "../../js/hooks/onchain_steps.ts"
import {
  sendStep,
  signStep,
  NothingSent,
  type SelectedWallet,
  type SignatureStep,
  type SwitchChain,
  type TransactionStep,
} from "../../js/wallet_actions/send_step.ts"

// The network switch before a wallet sends or signs, after ash-template's
// `send_step.test.ts`. The wallet moves only through its own switch, Privy's,
// which adds the network the way each wallet app needs.

const BASE = 8453
const SIGNER = `0x${"3".repeat(40)}`
const HASH = `0x${"ab".repeat(32)}`
const SIGNATURE = `0x${"cd".repeat(65)}`
const chain = {chain_id: BASE}
const step: TransactionStep = {kind: "transaction", step: "buy", to: `0x${"1".repeat(40)}`, data: "0x", value: "0x0"}
const signature: SignatureStep = {kind: "signature", step: "sign", typed_data: {}}

// A wallet app on network `on`. `switching` says what its switch does with each
// ask: the network it ends on, an error it rejects with, or a promise for either.
function walletOn(
  on: number,
  switching: (wanted: number) => number | Error | Promise<number | Error> = wanted => wanted,
) {
  let current = on
  const sent: unknown[] = []
  const switches: number[] = []
  const switchChain: SwitchChain = async wanted => {
    switches.push(wanted)
    const answer = await switching(wanted)
    if (answer instanceof Error) throw answer
    current = answer
  }
  const selected: SelectedWallet = {
    address: SIGNER,
    switchChain,
    provider: {
      request: async ({method, params}) => {
        if (method === "eth_chainId") return `0x${current.toString(16)}`
        if (method === "eth_accounts") return [SIGNER]
        if (method === "eth_sendTransaction") {
          sent.push(params?.[0])
          return HASH
        }
        if (method === "eth_signTypedData_v4") {
          sent.push(params)
          return SIGNATURE
        }
        throw new Error(`unexpected ${method}`)
      },
    },
  }
  return {sent, switches, selected}
}

function walletError(code: number, message: string): Error {
  return Object.assign(new Error(message), {code})
}

const sendBoth = [
  (wallet: SelectedWallet) => sendStep(chain, SIGNER, step, wallet, () => {}),
  (wallet: SelectedWallet) => signStep(chain, SIGNER, signature, wallet, () => {}),
]

// One press of the hook's Buy, with the server's reply already in hand.
function pressBuy(wallet: SelectedWallet) {
  const review: Review = {id: "r1", component_id: "c1", signer: SIGNER, chain, steps: [step], inputs: {}}
  const reports: unknown[] = []
  const root = {querySelectorAll: () => []} as unknown as HTMLElement
  const ask = async () => [{status: "fulfilled" as const, value: {reply: {review, send: "buy"}}}]
  return {reports, pressed: press(root, "buy", async () => wallet, ask, (event, payload) => reports.push([event, payload]))}
}

test("a wallet already on the step's network sends and signs without being asked to switch", async () => {
  for (const send of sendBoth) {
    const wallet = walletOn(BASE)
    await send(wallet.selected)
    assert.deepEqual(wallet.switches, [])
    assert.equal(wallet.sent.length, 1)
  }
})

test("a wallet on another network is moved by its own switch, then sends and signs", async () => {
  for (const send of sendBoth) {
    const wallet = walletOn(1)
    await send(wallet.selected)
    assert.deepEqual(wallet.switches, [BASE])
    assert.equal(wallet.sent.length, 1)
  }
})

// Invariant: nothing reaches the wallet's send while it is off the step's
// network, and the press reports which: the person said no to the switch (4001,
// however the wallet wraps it), or the wallet could not switch or is still
// elsewhere.
test("a declined switch is switch_declined, any other failure network_mismatch, and nothing is sent", async () => {
  const cases: Array<[string, () => number | Error]> = [
    ["switch_declined", () => walletError(4001, "User rejected the request.")],
    ["switch_declined", () => Object.assign(new Error("wrapped"), {cause: walletError(4001, "rejected")})],
    ["network_mismatch", () => walletError(4902, "Unrecognized chain ID")],
    ["network_mismatch", () => new Error("Unsupported chainId: 8453")],
    ["network_mismatch", () => walletError(-32603, "Internal error")],
    // The switch answered, but the wallet still reports another network.
    ["network_mismatch", () => 1],
  ]

  for (const [reason, switching] of cases) {
    const wallet = walletOn(1, switching)
    const {reports, pressed} = pressBuy(wallet.selected)

    assert.deepEqual(await pressed, {reason})
    assert.deepEqual(reports, [["step_failed", {step: "buy", reason, form: {}}]])
    assert.deepEqual(wallet.switches, [BASE])
    assert.deepEqual(wallet.sent, [])
  }
})

test("a press asks the switch again each time the wallet stays elsewhere", async () => {
  const wallet = walletOn(1, () => walletError(4001, "User rejected the request."))

  for (let press = 0; press < 3; press++) {
    await assert.rejects(sendStep(chain, SIGNER, step, wallet.selected, () => {}), NothingSent)
  }
  assert.deepEqual(wallet.switches, [BASE, BASE, BASE])
  assert.deepEqual(wallet.sent, [])
})

test("a second press while the first's switch is still open reaches the wallet too", async () => {
  const answers: Array<(network: number) => void> = []
  const wallet = walletOn(1, () => new Promise<number>(answer => answers.push(answer)))

  const first = pressBuy(wallet.selected)
  const second = pressBuy(wallet.selected)
  for (let turn = 0; answers.length < 2 && turn < 50; turn++) await new Promise(resolve => setImmediate(resolve))

  // Both presses asked the wallet to switch before either was answered.
  assert.deepEqual(wallet.switches, [BASE, BASE])
  for (const answer of answers) answer(BASE)

  assert.deepEqual(await first.pressed, {transaction_hash: HASH})
  assert.deepEqual(await second.pressed, {transaction_hash: HASH})
  assert.equal(wallet.sent.length, 2)
})
