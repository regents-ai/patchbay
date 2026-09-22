import assert from "node:assert/strict";
import {test} from "node:test";
import {prepareWalletRequest, signedWalletRequest, walletTarget, walletOrigin} from "../src/wallet.js";
const address = "0x" + "a".repeat(40), receipt = "fixture.receipt", base = "https://patchbay.help";
const target = walletTarget("execute", "10000000-0000-0000-0000-000000000001");
const signature = "0x" + "1".repeat(130), now = 1800000000;

test("external signing binds payment bytes, method, path, wallet, receipt and expiry", () => {
  const request = prepareWalletRequest(base, target, {receipt, wallet_address: address, payment_signature: "x402-authorization"}, now, "a".repeat(32));
  assert.ok(request.message.includes('"@method": post'));
  assert.ok(request.message.includes('"content-digest": sha-256=:'));
  assert.deepEqual(JSON.parse(request.body), {payment_signature: "x402-authorization"});
  const signed = signedWalletRequest(base, target, {request, signature}, now);
  assert.equal(signed.body, request.body);
  assert.equal(signed.headers["payment-signature"], undefined);
  assert.equal(signed.headers.cookie, undefined);
  for (const change of [r => r.body = '{}', r => r.path += '/other', r => r.method = 'GET',
    r => r.origin = 'https://example.invalid', r => r.headers['x-agent-wallet-address'] = '0x' + 'b'.repeat(40),
    r => r.headers['x-siwa-receipt'] = 'different', r => r.headers.cookie = 'untrusted', r => r.message += 'x']) {
    const altered = structuredClone(request); change(altered);
    assert.throws(() => signedWalletRequest(base, target, {request: altered, signature}, now));
  }
  assert.throws(() => signedWalletRequest(base, target, {request, signature}, now + 120));
});

test("recovery uses a fresh signed GET and cannot send a new payment", () => {
  const get = walletTarget("get", target.id);
  const r = prepareWalletRequest(base, get, {receipt, wallet_address: address}, now);
  assert.equal(r.method, "GET"); assert.equal(r.body, undefined);
  assert.equal(signedWalletRequest(base, get, {request: r, signature}, now).headers['content-digest'], undefined);
  assert.throws(() => prepareWalletRequest(base, get, {receipt, wallet_address: address, payment_signature: 'forbidden'}, now));
  assert.throws(() => walletTarget("get", "../profile"));
  for (const origin of ['http://remote.invalid', 'https://u:p@example.com', 'https://example.com/path']) assert.throws(() => walletOrigin(origin));
});

test("an assist request freezes the assist kind, and its read-back is a signed GET that cannot pay", () => {
  const request = walletTarget("assist_request", null);
  const args = {goal: "Book the 9am table", site_url: "https://bookings.example.com/app", sign_in: "unknown", expected_result: "A booking reference"};
  const prepared = prepareWalletRequest(base, request, {receipt, wallet_address: address, args}, now, "b".repeat(32));
  assert.equal(prepared.method, "POST"); assert.equal(prepared.path, "/api/agent/payment_intents");
  assert.deepEqual(JSON.parse(prepared.body), {kind: "jev_assist", args});
  assert.equal(signedWalletRequest(base, request, {request: prepared, signature}, now).body, prepared.body);
  // A request signed for a priority report is not one for an assist, and the other way round.
  assert.throws(() => signedWalletRequest(base, walletTarget("prepare", null), {request: prepared, signature}, now));
  const report = prepareWalletRequest(base, walletTarget("prepare", null), {receipt, wallet_address: address, args}, now, "b".repeat(32));
  assert.throws(() => signedWalletRequest(base, request, {request: report, signature}, now));
  assert.throws(() => prepareWalletRequest(base, request, {receipt, wallet_address: address, args, payment_signature: "forbidden"}, now));

  const read = walletTarget("assist_get", target.id);
  const get = prepareWalletRequest(base, read, {receipt, wallet_address: address}, now);
  assert.equal(get.method, "GET"); assert.equal(get.path, `/api/agent/assists/${target.id}`); assert.equal(get.body, undefined);
  assert.equal(signedWalletRequest(base, read, {request: get, signature}, now).headers["content-digest"], undefined);
  assert.throws(() => prepareWalletRequest(base, read, {receipt, wallet_address: address, payment_signature: "forbidden"}, now));
  assert.throws(() => walletTarget("assist_get", "../profile"));
});

test("pairing signs the code alone, and a request signed for pairing is nothing else", () => {
  const pair = walletTarget("pair", null);
  const prepared = prepareWalletRequest(base, pair, {receipt, wallet_address: address, code: "ABCDE-FGHJK"}, now, "c".repeat(32));
  assert.equal(prepared.method, "POST"); assert.equal(prepared.path, "/api/agent/pairing");
  assert.deepEqual(JSON.parse(prepared.body), {code: "ABCDE-FGHJK"});
  assert.equal(signedWalletRequest(base, pair, {request: prepared, signature}, now).body, prepared.body);
  for (const code of ["", "A".repeat(65), 12345, undefined]) {
    assert.throws(() => prepareWalletRequest(base, pair, {receipt, wallet_address: address, code}, now));
  }
  assert.throws(() => prepareWalletRequest(base, pair, {receipt, wallet_address: address, code: "ABCDE-FGHJK", args: {}}, now));
  const altered = structuredClone(prepared); altered.body = JSON.stringify({code: "ABCDE-FGHJK", person: "someone"});
  assert.throws(() => signedWalletRequest(base, pair, {request: altered, signature}, now));
  assert.throws(() => signedWalletRequest(base, walletTarget("prepare", null), {request: prepared, signature}, now));
});

import {spawn} from "node:child_process";
import {fixture} from "./helpers.js";
import {fileURLToPath} from "node:url";
function invokeWallet(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [fileURLToPath(new URL("../bin/patchbay.js", import.meta.url)), ...args], {stdio: ["pipe", "pipe", "pipe"]});
    let output = "";
    child.stdout.on("data", chunk => output += chunk);
    child.on("error", reject);
    child.on("close", code => { try { resolve({code, json: JSON.parse(output)}); } catch (error) { reject(error); } });
    child.stdin.end(JSON.stringify(input));
  });
}

test("unclear signed execution replies preserve the body and an owned recovery route, without retry", async t => {
  const api = await fixture(t);
  for (const answer of [{status: 500, body: {error: "server failed"}}, {status: 200, body: {proxy: "not a payment result"}}, {status: 502, type: "text/html", text: "bad gateway"}, {hang: true}]) {
    api.respond(answer);
    const request = prepareWalletRequest(api.origin, target, {receipt, wallet_address: address, payment_signature: "fixture-x402"});
    const before = api.requests.length;
    const result = await invokeWallet(["payments", "execute", target.id, "--base-url", api.origin, "--timeout-ms", "100"], {request, signature});
    assert.equal(result.code, 1);
    assert.equal(result.json.outcome_unknown, true);
    assert.equal(result.json.recovery_required, true);
    assert.equal(result.json.payment_intent_id, target.id);
    assert.equal(result.json.status_url, `${api.origin}/api/agent/payment_intents/${target.id}`);
    if (answer.body) assert.deepEqual(result.json.body, answer.body);
    assert.equal(api.requests.length, before + 1);
  }
});
