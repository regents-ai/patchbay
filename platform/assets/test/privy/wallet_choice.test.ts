import assert from "node:assert/strict"
import {test} from "node:test"

import {accountActiveWallet, sendingWallet} from "../../js/privy/wallet_choice.ts"

// Sean, 29 Oct 2026 ("75. a"): Privy makes every person a wallet at sign-in, so
// a wallet sign-in now has two linked wallets in the tab, and an email or Google
// sign-in often has a wallet app open on a wallet the account does not link.
// Only the account's own wallets send (regent-workflow, wallet identity), as
// ash-template's accountActiveWallet and wallet sync choose them.
const own = {address: "0x" + "E".repeat(40), type: "ethereum"}
const made = {address: "0x" + "7".repeat(40), type: "ethereum"}
const stranger = {address: "0x" + "9".repeat(40), type: "ethereum"}
const linked = [own.address.toLowerCase(), made.address.toLowerCase()]

test("with two linked wallets in the tab and none named by Privy, the account's own wallet sends", () => {
  assert.equal(sendingWallet(null, [own, made], linked, own.address.toLowerCase()), own)
  assert.equal(sendingWallet(undefined, [made, own], linked, made.address.toLowerCase()), made)
})

test("an active wallet the account does not link is ignored, and the account's own wallet sends", () => {
  assert.equal(sendingWallet(stranger, [stranger, own, made], linked, own.address.toLowerCase()), own)
  assert.equal(sendingWallet(stranger, [stranger, made], [made.address.toLowerCase()], made.address.toLowerCase()), made)
})

test("Privy's active wallet sends when the account links it and the tab holds it", () => {
  assert.equal(sendingWallet(made, [own, made], linked, own.address.toLowerCase()), made)
  assert.equal(sendingWallet({...made}, [own, made], linked, own.address.toLowerCase()), made)
})

test("a Privy wallet made after the sign-in handed over is not the account's until the next sign-in", () => {
  assert.equal(sendingWallet(made, [own, made], [own.address.toLowerCase()], own.address.toLowerCase()), own)
})

test("the one linked wallet in the tab sends; several, none the account's own, is no wallet; none is none", () => {
  assert.equal(sendingWallet(null, [stranger, made], linked, null), made)
  assert.equal(sendingWallet(null, [own, made], linked, null), null)
  assert.equal(sendingWallet(null, [stranger], linked, own.address.toLowerCase()), null)
  assert.equal(sendingWallet({address: "So1ana", type: "solana"}, [made], [made.address.toLowerCase()], null), made)
})

test("signed out, Privy's active wallet stands when the tab holds it", () => {
  assert.equal(accountActiveWallet(stranger, [stranger], false, []), stranger)
  assert.equal(accountActiveWallet(stranger, [], false, []), null)
  assert.equal(accountActiveWallet(stranger, [stranger], true, linked), null)
})
