import assert from "node:assert/strict";
import test from "node:test";

import {payForIntent, shouldReplaySigned} from "../../js/webmcp/paid_actions.js";

function encodeChallenge(challenge) {
  return Buffer.from(JSON.stringify(challenge), "utf8").toString("base64");
}

function headers(map) {
  return {get: name => map[name] ?? map[name.toLowerCase()] ?? null};
}

function jsonResponse(status, body, headerMap = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    headers: headers(headerMap),
  };
}

test("shouldReplaySigned is only a 5xx without PAYMENT-RESPONSE", () => {
  assert.equal(shouldReplaySigned({status: 502, paymentResponse: null}), true);
  assert.equal(shouldReplaySigned({status: 500, paymentResponse: null}), true);
  assert.equal(shouldReplaySigned({status: 502, paymentResponse: "abc"}), false);
  assert.equal(shouldReplaySigned({status: 402, paymentResponse: null}), false);
  assert.equal(shouldReplaySigned({status: 409, paymentResponse: null}), false);
});

test("a 5xx after signing replays the same PAYMENT-SIGNATURE and never creates a second intent", async () => {
  const challenge = {
    accepts: [
      {
        scheme: "exact",
        network: "eip155:8453",
        asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        payTo: `0x${"1".repeat(40)}`,
        amount: "1000000",
        maxTimeoutSeconds: 300,
        extra: {name: "USD Coin", version: "2"},
      },
    ],
    extensions: {},
  };
  const requests = [];
  const fetchImpl = async (url, request) => {
    requests.push({url, method: request.method, headers: request.headers});
    if (url === "/api/payment_intents") {
      return jsonResponse(201, {id: "int_1", amount_usdc: "1.00"});
    }
    if (!request.headers["payment-signature"]) {
      return jsonResponse(402, {status: "payment_required"}, {
        "payment-required": encodeChallenge(challenge),
      });
    }
    if (requests.filter(item => item.headers["payment-signature"]).length < 3) {
      return jsonResponse(502, {error: "facilitator down"});
    }
    return jsonResponse(200, {status: "applied", receipt: {transaction_hash: "0xabc"}}, {
      "payment-response": "settled",
    });
  };

  const outcome = await payForIntent(
    {
      fetch: fetchImpl,
      csrfToken: "token",
      signer: async () => ({
        ok: true,
        address: `0x${"2".repeat(40)}`,
        signTypedData: async () => ({ok: true, signature: "0xdead"}),
      }),
    },
    {kind: "agent_tip", args: {profile_id: "agt_2", amount_usdc: "1.00"}},
  );

  const creates = requests.filter(item => item.url === "/api/payment_intents");
  const signed = requests.filter(item => item.headers["payment-signature"]);
  assert.equal(creates.length, 1);
  assert.equal(signed.length, 3);
  assert.equal(new Set(signed.map(item => item.headers["payment-signature"])).size, 1);
  assert.equal(outcome.status, 200);
  assert.equal(outcome.body.status, "applied");
});

test("an exhausted 5xx replay tells the agent not to pay again", async () => {
  const challenge = {
    accepts: [
      {
        scheme: "exact",
        network: "eip155:8453",
        asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        payTo: `0x${"1".repeat(40)}`,
        amount: "1000000",
        maxTimeoutSeconds: 300,
        extra: {name: "USD Coin", version: "2"},
      },
    ],
    extensions: {},
  };
  const fetchImpl = async (url, request) => {
    if (url === "/api/payment_intents") {
      return jsonResponse(201, {id: "int_9", amount_usdc: "1.00"});
    }
    if (!request.headers["payment-signature"]) {
      return jsonResponse(402, {status: "payment_required"}, {
        "payment-required": encodeChallenge(challenge),
      });
    }
    return jsonResponse(502, {error: "still down"});
  };

  const outcome = await payForIntent(
    {
      fetch: fetchImpl,
      signer: async () => ({
        ok: true,
        address: `0x${"2".repeat(40)}`,
        signTypedData: async () => ({ok: true, signature: "0xdead"}),
      }),
    },
    {kind: "agent_tip", args: {profile_id: "agt_2", amount_usdc: "1.00"}},
  );

  assert.equal(outcome.status, 502);
  assert.equal(outcome.body.payment_intent_id, "int_9");
  assert.match(outcome.body.next_action, /Do not pay again/);
});
