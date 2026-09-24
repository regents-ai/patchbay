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
  assert.equal(outcome.body.outcome, "unknown");
  assert.equal(outcome.body.recovery_required, true);
  assert.equal(outcome.body.status_url, "/api/payment_intents/int_9");
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

const cancellationChallenge = {
  accepts: [{scheme: "exact", network: "eip155:8453", asset: `0x${"a".repeat(40)}`,
    payTo: `0x${"b".repeat(40)}`, amount: "1000001", maxTimeoutSeconds: 300,
    extra: {name: "USD Coin", version: "2"}}],
  extensions: {},
};
const cancellationIntent = "12345678-1234-4234-8234-123456789012";
const cancellationAction = {kind: "agent_tip", args: {profile_id: "agt_recipient", amount_usdc: "1.000001"}};

test("a pre-aborted payment invocation does not prepare an intent or reach a signer", async () => {
  const controller = new AbortController();
  controller.abort();
  const outcome = await payForIntent({signal: controller.signal,
    fetch: () => assert.fail("unexpected request"), signer: () => assert.fail("unexpected signer")}, cancellationAction);
  assert.equal(outcome.body.problem_code, "canceled");
  assert.equal(outcome.body.outcome, "canceled");
  assert.equal(outcome.body.paid, undefined);
});

for (const phase of ["preparation", "challenge", "signer", "signature", "submission", "replay"]) {
  test(`aborting during ${phase} prevents the next payment phase and discards its late response`, async () => {
    const controller = new AbortController();
    const entered = deferred();
    const release = deferred();
    const requests = [];
    let signerCalls = 0, signatureCalls = 0, submissions = 0;
    const pause = async (at, value) => {
      if (at === phase) { entered.resolve(); await release.promise; }
      return value;
    };
    const fetch = async (url, request) => {
      requests.push({url, request});
      if (url === "/api/payment_intents") {
        return pause("preparation", jsonResponse(201, {id: cancellationIntent}));
      }
      if (!request.headers["payment-signature"]) {
        return pause("challenge", jsonResponse(402, {status: "payment_required"}, {
          "payment-required": encodeChallenge(cancellationChallenge),
        }));
      }
      submissions++;
      return pause(submissions === 1 ? "submission" : "replay", jsonResponse(502, {error: "uncertain settlement"}));
    };
    const pending = payForIntent({signal: controller.signal, fetch,
      signer: async () => {
        signerCalls++;
        return pause("signer", {ok: true, address: `0x${"c".repeat(40)}`,
          signTypedData: async () => { signatureCalls++; return pause("signature", {ok: true, signature: "synthetic"}); }});
      }}, cancellationAction);
    await entered.promise;
    controller.abort();
    release.resolve();
    const outcome = await pending;
    assert.equal(outcome.body.problem_code, "canceled");
    assert.equal(outcome.body.outcome, "unknown");
    assert.equal(outcome.body.payment_intent_id, cancellationIntent);
    assert.equal(outcome.body.status_url, `/api/payment_intents/${cancellationIntent}`);
    assert.equal(outcome.body.paid, undefined);
    assert.equal(requests.length, {preparation: 1, challenge: 2, signer: 2, signature: 2, submission: 3, replay: 4}[phase]);
    assert.equal(signerCalls, ["preparation", "challenge"].includes(phase) ? 0 : 1);
    assert.equal(signatureCalls, ["preparation", "challenge", "signer"].includes(phase) ? 0 : 1);
    assert.equal(submissions, phase === "submission" ? 1 : phase === "replay" ? 2 : 0);
    for (const {request} of requests) assert.equal(request.signal, controller.signal);
    if (submissions) assert.match(outcome.body.error, /may have settled/);
  });
}

test("an aborted signer rejection remains a cancellation instead of an unrelated failure", async () => {
  const controller = new AbortController();
  const fetch = async url => url === "/api/payment_intents"
    ? jsonResponse(201, {id: cancellationIntent})
    : jsonResponse(402, {}, {"payment-required": encodeChallenge(cancellationChallenge)});
  const outcome = await payForIntent({signal: controller.signal, fetch, signer: async () => {
    controller.abort();
    throw new Error("late provider failure");
  }}, cancellationAction);
  assert.equal(outcome.body.problem_code, "canceled");
  assert.equal(outcome.body.payment_intent_id, cancellationIntent);
});

for (const cancelFirst of [false, true]) {
  test(`concurrent payment invocations remain independent${cancelFirst ? " when one is canceled" : ""}`, async () => {
    const first = new AbortController(), second = new AbortController();
    const signatures = deferred();
    const bothSigning = deferred();
    const sent = [];
    let intentCount = 0, signingCount = 0;
    const options = signal => ({signal,
      fetch: async (url, request) => {
        if (url === "/api/payment_intents") return jsonResponse(201, {id: `intent_${++intentCount}`});
        if (!request.headers["payment-signature"]) {
          return jsonResponse(402, {}, {"payment-required": encodeChallenge(cancellationChallenge)});
        }
        sent.push({url, signature: request.headers["payment-signature"]});
        return jsonResponse(200, {status: "applied"});
      },
      signer: async () => ({ok: true, address: `0x${"d".repeat(40)}`, signTypedData: async () => {
        if (++signingCount === 2) bothSigning.resolve();
        await signatures.promise;
        return {ok: true, signature: "synthetic"};
      }}),
    });
    const one = payForIntent(options(first.signal), cancellationAction);
    const two = payForIntent(options(second.signal), cancellationAction);
    await bothSigning.promise;
    if (cancelFirst) first.abort();
    signatures.resolve();
    const [a, b] = await Promise.all([one, two]);
    assert.equal(intentCount, 2);
    assert.equal(signingCount, 2);
    assert.equal(sent.length, cancelFirst ? 1 : 2);
    assert.equal(b.body.status, "applied");
    assert.equal(a.body[cancelFirst ? "problem_code" : "status"], cancelFirst ? "canceled" : "applied");
    if (!cancelFirst) assert.equal(new Set(sent.map(value => value.signature)).size, 2);
  });
}

for (const lateResponse of ["applied", "abort_error"]) {
  test(`signed submission cancellation keeps recovery details after ${lateResponse}`, async () => {
    const controller = new AbortController();
    let submissions = 0;
    const fetch = async (url, request) => {
      if (url === "/api/payment_intents") return jsonResponse(201, {id: cancellationIntent});
      if (!request.headers["payment-signature"]) {
        return jsonResponse(402, {}, {"payment-required": encodeChallenge(cancellationChallenge)});
      }
      submissions++;
      controller.abort();
      if (lateResponse === "abort_error") throw new DOMException("Canceled", "AbortError");
      return jsonResponse(200, {status: "applied"});
    };
    const outcome = await payForIntent({signal: controller.signal, fetch,
      signer: async () => ({ok: true, address: `0x${"c".repeat(40)}`,
        signTypedData: async () => ({ok: true, signature: "synthetic"})})}, cancellationAction);
    assert.equal(outcome.body.problem_code, "canceled");
    assert.equal(outcome.body.outcome, "unknown");
    assert.equal(outcome.body.payment_intent_id, cancellationIntent);
    assert.equal(outcome.body.status_url, `/api/payment_intents/${cancellationIntent}`);
    assert.equal(outcome.body.paid, undefined);
    assert.equal(outcome.body.status, undefined);
    assert.equal(submissions, 1);
  });
}

for (const refusal of ["preparation", "unsupported_challenge", "signed_out", "refused"]) {
  test(`uncanceled ${refusal} refusal retains its existing result`, async () => {
    const intent = {id: cancellationIntent, amount_usdc: "1.000001"};
    const body = {status: "payment_required", error: "synthetic refusal"};
    const challenge = refusal === "unsupported_challenge" ? {accepts: []} : cancellationChallenge;
    const result = await payForIntent({
      fetch: async url => url === "/api/payment_intents"
        ? jsonResponse(refusal === "preparation" ? 422 : 201, refusal === "preparation" ? body : intent)
        : jsonResponse(402, body, {"payment-required": encodeChallenge(challenge)}),
      signer: async () => refusal === "signed_out" ? {ok: false, reason: "signed_out"}
        : {ok: true, address: `0x${"c".repeat(40)}`, signTypedData: async () => ({ok: false, reason: "refused"})},
    }, cancellationAction);
    assert.deepEqual(result, refusal === "preparation"
      ? {status: 422, body}
      : {status: 402, body, intent, unsigned: refusal});
  });
}


test("a lost response after signing retains an unknown outcome and owner recovery link", async () => {
  let signatures = 0;
  const outcome = await payForIntent({
    fetch: async (url, request) => {
      if (url === "/api/payment_intents") return jsonResponse(201, {id: cancellationIntent});
      if (!request.headers["payment-signature"]) return jsonResponse(402, {}, {
        "payment-required": encodeChallenge(cancellationChallenge),
      });
      throw new Error("connection lost after dispatch");
    },
    signer: async () => ({ok: true, address: `0x${"c".repeat(40)}`,
      signTypedData: async () => { signatures++; return {ok: true, signature: "0xdead"}; }}),
  }, cancellationAction);
  assert.equal(signatures, 1);
  assert.equal(outcome.body.outcome, "unknown");
  assert.equal(outcome.body.recovery_required, true);
  assert.equal(outcome.body.status_url, `/api/payment_intents/${cancellationIntent}`);
});
