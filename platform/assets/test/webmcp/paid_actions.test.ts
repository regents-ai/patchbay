import assert from "node:assert/strict";
import test from "node:test";

import {payForIntent, shouldReplaySigned} from "../../js/webmcp/paid_actions.ts";
import type {PaymentRequestInit, PaymentWallet, PayOptions} from "../../js/webmcp/paid_actions.ts";

const SIGNER = `0x${"c".repeat(40)}`;
const SIGNATURE = `0x${"5".repeat(130)}`;
const INTENT = "12345678-1234-4234-8234-123456789012";
const ACTION = {kind: "agent_tip", args: {profile_id: "agt_recipient", amount_usdc: "1.000001"}};

const TYPED_DATA = {
  types: {TransferWithAuthorization: [{name: "from", type: "address"}]},
  primaryType: "TransferWithAuthorization",
  domain: {name: "USD Coin", version: "2", chainId: 8453, verifyingContract: `0x${"a".repeat(40)}`},
  message: {from: SIGNER, to: `0x${"b".repeat(40)}`, value: "1000001", nonce: `0x${"1".repeat(64)}`},
};

type SentBody = Record<string, unknown>;
type Sent = {url: string; request: PaymentRequestInit; body: SentBody | undefined};
type WalletAsk = {method: string; params?: unknown[]};

function review(id = "review_1", signer = SIGNER) {
  return {
    id,
    signer,
    chain: {chain_id: 8453, name: "Base", rpc_url: "https://mainnet.base.org"},
    steps: [{kind: "signature", step: "pay", typed_data: TYPED_DATA}],
  };
}

function jsonResponse(status: number, body: unknown, headerMap: Record<string, string> = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    headers: {get: (name: string) => headerMap[name.toLowerCase()] ?? null},
  };
}

function sent(request: PaymentRequestInit): SentBody | undefined {
  return request.body === undefined ? undefined : JSON.parse(request.body);
}

// A wallet app that answers by method name, as the template's stand-in does.
function standInWallet({address = SIGNER, chainId = 8453, sign, switchTo}: {
  address?: string;
  chainId?: number;
  sign?: (params: unknown[] | undefined) => unknown;
  switchTo?: number;
} = {}) {
  const asked: WalletAsk[] = [];
  let chain = chainId;
  const provider = {
    request: async ({method, params}: WalletAsk): Promise<unknown> => {
      asked.push({method, params});
      if (method === "eth_chainId") return `0x${chain.toString(16)}`;
      if (method === "eth_accounts") return [address];
      if (method === "wallet_switchEthereumChain") {
        if (!switchTo) throw Object.assign(new Error("User rejected the request."), {code: 4001});
        chain = switchTo;
        return null;
      }
      if (method === "eth_signTypedData_v4") return sign ? sign(params) : SIGNATURE;
      throw new Error(`unexpected ${method}`);
    },
  };
  const wallet = async (): Promise<PaymentWallet> => ({ok: true, wallet: {address, provider}});
  return {asked, wallet};
}

type Answer = ReturnType<typeof jsonResponse>;

// Patchbay's side: an intent, then the review for the active wallet, then an
// answer to the signature.
function patchbay({signedAnswer = () => jsonResponse(200, {status: "applied"}), unsigned}: {
  signedAnswer?: (body: SentBody, requests: Sent[]) => Answer;
  unsigned?: (body: SentBody) => Answer;
} = {}) {
  const requests: Sent[] = [];
  let intents = 0;
  const fetch = async (url: string, request: PaymentRequestInit) => {
    requests.push({url, request, body: sent(request)});
    if (url === "/api/payment_intents") return jsonResponse(201, {id: intents++ ? `${INTENT}-${intents}` : INTENT});
    const body = sent(request)!;
    if (!body.signature) {
      return unsigned ? unsigned(body) : jsonResponse(402, {status: "payment_required", review: review()});
    }
    return signedAnswer(body, requests);
  };
  return {fetch, requests};
}

test("shouldReplaySigned is only a 5xx without PAYMENT-RESPONSE", () => {
  assert.equal(shouldReplaySigned({status: 502, paymentResponse: null}), true);
  assert.equal(shouldReplaySigned({status: 500, paymentResponse: null}), true);
  assert.equal(shouldReplaySigned({status: 502, paymentResponse: "abc"}), false);
  assert.equal(shouldReplaySigned({status: 402, paymentResponse: null}), false);
  assert.equal(shouldReplaySigned({status: 409, paymentResponse: null}), false);
});

test("the wallet signs Patchbay's typed data and only the signature goes back", async () => {
  const {fetch, requests} = patchbay();
  const {asked, wallet} = standInWallet();

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  const signing = asked.find(one => one.method === "eth_signTypedData_v4")!;
  assert.deepEqual(signing.params, [SIGNER, JSON.stringify(TYPED_DATA)]);
  assert.equal(asked.filter(one => one.method !== "eth_signTypedData_v4").at(-1)!.method, "eth_chainId");
  assert.deepEqual(requests[1].body, {active_wallet: SIGNER});
  assert.deepEqual(requests[2].body, {active_wallet: SIGNER, review_id: "review_1", signature: SIGNATURE});
  assert.equal(outcome.status, 200);
  assert.equal(outcome.body!.status, "applied");
});

test("two presses in a row both reach the wallet, each with its own intent", async () => {
  const {fetch, requests} = patchbay();
  const {asked, wallet} = standInWallet();

  const [one, two] = await Promise.all([payForIntent({fetch, wallet}, ACTION), payForIntent({fetch, wallet}, ACTION)]);

  assert.equal(asked.filter(each => each.method === "eth_signTypedData_v4").length, 2);
  assert.equal(requests.filter(each => each.url === "/api/payment_intents").length, 2);
  assert.equal(one.body!.status, "applied");
  assert.equal(two.body!.status, "applied");
});

test("a declined signature is wallet_declined and nothing goes back", async () => {
  const {fetch, requests} = patchbay();
  const {wallet} = standInWallet({sign: () => { throw Object.assign(new Error("User rejected the request."), {code: 4001}); }});

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.unsigned, "wallet_declined");
  assert.equal(outcome.status, 402);
  assert.equal(requests.length, 2);
});

test("a wallet that stays on another network is asked nothing to sign", async () => {
  const {fetch, requests} = patchbay();
  const {asked, wallet} = standInWallet({chainId: 1});

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.unsigned, "network_mismatch");
  assert.equal(asked.some(one => one.method === "eth_signTypedData_v4"), false);
  assert.equal(requests.length, 2);
});

test("a wallet that switches to Base when asked then signs", async () => {
  const {fetch} = patchbay();
  const {asked, wallet} = standInWallet({chainId: 1, switchTo: 8453});

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.deepEqual(asked.find(one => one.method === "wallet_switchEthereumChain")!.params, [{chainId: "0x2105"}]);
  assert.equal(outcome.body!.status, "applied");
});

test("a wallet whose account is not the review's signer is asked nothing to sign", async () => {
  const {fetch} = patchbay();
  const {asked, wallet} = standInWallet({address: `0x${"e".repeat(40)}`});

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.unsigned, "wallet_unavailable");
  assert.equal(asked.some(one => one.method === "eth_signTypedData_v4"), false);
});

test("a wallet Patchbay does not know for the account comes back with its note", async () => {
  const note = "You're signed in with 0xcc…cc, but your wallet app has 0xee…ee open.";
  const {fetch, requests} = patchbay({
    unsigned: () => jsonResponse(402, {status: "payment_required", problem_code: "wallet_mismatch", wallet_note: note}),
  });
  const {asked, wallet} = standInWallet({address: `0x${"e".repeat(40)}`});

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.unsigned, "wallet_mismatch");
  assert.equal(outcome.body!.wallet_note, note);
  assert.deepEqual(asked, []);
  assert.equal(requests.length, 2);
});

test("with no wallet to sign, Patchbay is still asked and the reason comes back", async () => {
  const {fetch, requests} = patchbay({
    unsigned: () => jsonResponse(402, {status: "payment_required", problem_code: "wallet_unavailable"}),
  });

  const outcome = await payForIntent({fetch, wallet: async () => ({ok: false, reason: "signed_out"})}, ACTION);

  assert.deepEqual(requests[1].body, {active_wallet: null});
  assert.equal(outcome.unsigned, "signed_out");
});

test("a preparation refusal comes back untouched", async () => {
  const body = {errors: ["amount_usdc: must be an amount"], problem_code: "invalid"};
  const outcome = await payForIntent({
    fetch: async () => jsonResponse(422, body),
    wallet: () => assert.fail("no wallet before an intent exists"),
  }, ACTION);
  assert.deepEqual(outcome, {status: 422, body});
});

test("a 5xx after signing replays the same signature and never creates a second intent", async () => {
  const {fetch, requests} = patchbay({
    signedAnswer: (_body, all) => all.filter(one => one.body?.signature).length < 3
      ? jsonResponse(502, {error: "facilitator down"})
      : jsonResponse(200, {status: "applied"}, {"payment-response": "settled"}),
  });
  const {wallet} = standInWallet();

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  const signed = requests.filter(one => one.body?.signature);
  assert.equal(requests.filter(one => one.url === "/api/payment_intents").length, 1);
  assert.equal(signed.length, 3);
  assert.equal(new Set(signed.map(one => JSON.stringify(one.body))).size, 1);
  assert.equal(outcome.body!.status, "applied");
});

test("an exhausted 5xx replay tells the agent not to pay again", async () => {
  const {fetch} = patchbay({signedAnswer: () => jsonResponse(502, {error: "still down"})});
  const {wallet} = standInWallet();

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.status, 502);
  assert.equal(outcome.body!.payment_intent_id, INTENT);
  assert.match(outcome.body!.next_action as string, /Do not pay again/);
  assert.equal(outcome.body!.outcome, "unknown");
  assert.equal(outcome.body!.recovery_required, true);
  assert.equal(outcome.body!.status_url, `/api/payment_intents/${INTENT}`);
});

test("a lost response after signing keeps an unknown outcome and the recovery link", async () => {
  const {fetch} = patchbay({signedAnswer: () => { throw new Error("connection lost after dispatch"); }});
  const {wallet} = standInWallet();

  const outcome = await payForIntent({fetch, wallet}, ACTION);

  assert.equal(outcome.body!.outcome, "unknown");
  assert.equal(outcome.body!.recovery_required, true);
  assert.equal(outcome.body!.status_url, `/api/payment_intents/${INTENT}`);
});

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>(yes => { resolve = yes; });
  return {promise, resolve};
}

test("a pre-aborted payment invocation does not prepare an intent or reach a wallet", async () => {
  const controller = new AbortController();
  controller.abort();
  const outcome = await payForIntent({signal: controller.signal,
    fetch: () => assert.fail("unexpected request"), wallet: () => assert.fail("unexpected wallet")}, ACTION);
  assert.equal(outcome.body!.problem_code, "canceled");
  assert.equal(outcome.body!.outcome, "canceled");
});

for (const phase of ["preparation", "wallet", "review", "signature", "submission", "replay"] as const) {
  test(`aborting during ${phase} prevents the next payment phase and discards its late response`, async () => {
    const controller = new AbortController();
    const entered = deferred();
    const release = deferred();
    const pause = async <T>(at: typeof phase, value: T): Promise<T> => {
      if (at === phase) { entered.resolve(); await release.promise; }
      return value;
    };
    let submissions = 0;
    const requests: PaymentRequestInit[] = [];
    const fetch = async (url: string, request: PaymentRequestInit) => {
      requests.push(request);
      if (url === "/api/payment_intents") return pause("preparation", jsonResponse(201, {id: INTENT}));
      if (!sent(request)!.signature) {
        return pause("review", jsonResponse(402, {status: "payment_required", review: review()}));
      }
      submissions++;
      return pause(submissions === 1 ? "submission" : "replay", jsonResponse(502, {error: "uncertain settlement"}));
    };
    const {asked, wallet} = standInWallet({sign: () => pause("signature", SIGNATURE)});
    const options: PayOptions = {signal: controller.signal, fetch,
      wallet: () => pause("wallet", null).then(() => wallet())};
    const pending = payForIntent(options, ACTION);
    await entered.promise;
    controller.abort();
    release.resolve();
    const outcome = await pending;
    const signatures = asked.filter(one => one.method === "eth_signTypedData_v4").length;
    assert.equal(outcome.body!.problem_code, "canceled");
    assert.equal(outcome.body!.outcome, "unknown");
    assert.equal(outcome.body!.payment_intent_id, INTENT);
    assert.equal(requests.length, {preparation: 1, wallet: 1, review: 2, signature: 2, submission: 3, replay: 4}[phase]);
    assert.equal(signatures, ["signature", "submission", "replay"].includes(phase) ? 1 : 0);
    assert.equal(submissions, phase === "submission" ? 1 : phase === "replay" ? 2 : 0);
    for (const request of requests) assert.equal(request.signal, controller.signal);
    if (submissions) assert.match(outcome.body!.error as string, /may have settled/);
  });
}
