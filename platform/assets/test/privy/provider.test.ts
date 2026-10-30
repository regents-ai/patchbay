import assert from "node:assert/strict"
import {test} from "node:test"

import {hasWallet, providerConfig} from "../../js/privy/provider.ts"

// Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
// The sign-in choices are the Privy dashboard's, so nothing limits them here, and
// Privy makes every person their own Ethereum wallet when they sign in.
test("Privy is given ash-template's settings: no limit on the sign-in choices, a wallet for everyone", () => {
  assert.deepEqual(providerConfig, {
    embeddedWallets: {showWalletUIs: true, ethereum: {createOnLogin: "all-users"}},
  })
  assert.equal("loginMethods" in providerConfig, false)
})

const email = {type: "email", address: "made@example.com"}
const made = {type: "wallet", chainType: "ethereum", walletClientType: "privy", address: "0x" + "7".repeat(40)}
const own = {type: "wallet", chainType: "ethereum", walletClientType: "metamask", address: "0x" + "e".repeat(40)}
const solana = {type: "wallet", chainType: "solana", walletClientType: "privy", address: "So1ana"}
const person = (...linkedAccounts: object[]) => ({linkedAccounts}) as unknown as Parameters<typeof hasWallet>[0]

test("an email sign-in is handed over only once Privy has made its wallet", () => {
  assert.equal(hasWallet(person(email)), false)
  assert.equal(hasWallet(person(email, made)), true)
})

test("a wallet sign-in has its wallet at once; a Solana wallet alone is no wallet; nobody has none", () => {
  assert.equal(hasWallet(person(own)), true)
  assert.equal(hasWallet(person(own, made)), true)
  assert.equal(hasWallet(person(email, solana)), false)
  assert.equal(hasWallet(null), false)
})
