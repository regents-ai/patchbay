import assert from "node:assert/strict"
import {test} from "node:test"

import {hasWallet, providerConfig, signInChoices, walletChainId, type Chain} from "../../js/privy/provider.ts"

// Privy's own description of the site's wallet chain, as the bridge finds it in
// Privy's list of networks.
const base = {id: 8453, name: "Base"} as Chain

// Sean, 29 Oct 2026 ("75. a"): email sign-in on Patchbay, as ash-template has it.
// The sign-in choices are the Privy dashboard's, so nothing limits them here, and
// Privy makes every person their own Ethereum wallet when they sign in.
test("Privy is given ash-template's settings: no limit on the sign-in choices, a wallet for everyone", () => {
  const config = providerConfig(null, base)
  assert.deepEqual(config, {
    embeddedWallets: {showWalletUIs: true, ethereum: {createOnLogin: "all-users"}},
    defaultChain: base,
    supportedChains: [base],
  })
  assert.equal("loginMethods" in config, false)
})

test("the open address offers email only and shows no wallet screens, and Privy still makes the wallet", () => {
  assert.deepEqual(providerConfig("email", base), {
    loginMethods: ["email"],
    embeddedWallets: {showWalletUIs: false, ethereum: {createOnLogin: "all-users"}},
    defaultChain: base,
    supportedChains: [base],
  })
})

const page = (name: string, content: string | null) => ({
  querySelector: (selector: string) =>
    selector === `meta[name="${name}"]` && content !== null ? {getAttribute: () => content} : null,
})

test("the page's sign-in choices come from its privy-sign-in meta tag", () => {
  assert.equal(signInChoices(page("privy-sign-in", "email")), "email")
  assert.equal(signInChoices(page("privy-sign-in", null)), null)
})

test("the wallet chain comes from the page's wallet-chain-id meta tag, and a page without one names none", () => {
  assert.equal(walletChainId(page("wallet-chain-id", "8453")), 8453)
  assert.ok(Number.isNaN(walletChainId(page("wallet-chain-id", null))))
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
