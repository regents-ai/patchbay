import assert from "node:assert/strict"
import {test} from "node:test"

import {topUpByCard, topUpWords} from "../../js/card_topup.js"

const page = appId => ({
  querySelector: selector =>
    selector === 'meta[name="privy-app-id"]' && appId !== null ? {getAttribute: () => appId} : null,
})

test("a card top-up goes to Privy's with the page's application", async () => {
  const asked = []
  const bridge = {addFundsByCard: async appId => { asked.push(appId); return {ok: true, status: "confirmed"} }}
  const outcome = await topUpByCard(page("app-1"), {loadBridge: async () => bridge})
  assert.deepEqual(outcome, {ok: true, status: "confirmed"})
  assert.deepEqual(asked, ["app-1"])
})

test("with no Privy application, or none that loads, nothing opens", async () => {
  assert.deepEqual(await topUpByCard(page(null), {loadBridge: async () => assert.fail("loaded")}), {ok: false, reason: "unconfigured"})
  assert.deepEqual(await topUpByCard(page("app-1"), {loadBridge: async () => null}), {ok: false, reason: "unloadable"})
})

test("each answer is said in words, and an unknown one as unfinished", () => {
  assert.match(topUpWords({ok: true, status: "confirmed"}), /on its way/)
  assert.match(topUpWords({ok: true, status: "submitted"}), /once the card provider finishes/)
  assert.match(topUpWords({ok: false, reason: "no_wallet"}), /Sign in with a wallet/)
  assert.match(topUpWords({ok: false, reason: "unfinished"}), /did not finish/)
  assert.match(topUpWords({ok: false, reason: "something new"}), /did not finish/)
})
