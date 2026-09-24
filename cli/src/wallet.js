import {createHash, randomBytes} from "node:crypto";
import {UsageError} from "./cli.js";

const walletPattern = /^0x[0-9a-f]{40}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const components = ["@method", "@path", "x-siwa-receipt", "x-key-id", "x-timestamp", "x-agent-wallet-address", "x-agent-chain-id"];
const fail = () => { throw new UsageError("Invalid wallet input. Use the documented pipe-only external signing flow in docs/wallet-author.md."); };
const object = value => value && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",");

export function walletOrigin(value) {
  let url;
  try { url = new URL(value); } catch { return fail(); }
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) ||
      url.username || url.password || url.pathname !== "/" || url.search || url.hash) fail();
  return url.origin;
}

// The operations that freeze terms, and the payment kind each one freezes.
const prepares = {prepare: "special_post", assist_request: "jev_assist"};
const reads = ["get", "assist_get"];

export function walletTarget(operation, id, values = {}) {
  const phase = values.phase ?? "send";
  if (!["prepare", "send"].includes(phase)) fail();
  if (["execute", ...reads].includes(operation) && !uuidPattern.test(id ?? "")) fail();
  return {operation, phase, id, siwaUrl: values["siwa-url"], walletAddress: values["wallet-address"]};
}

function targetFor(target) {
  if (target.operation in prepares) return {method: "POST", path: "/api/agent/payment_intents"};
  if (target.operation === "execute") return {method: "POST", path: `/api/agent/payment_intents/${target.id}/execute`};
  if (target.operation === "get") return {method: "GET", path: `/api/agent/payment_intents/${target.id}`};
  if (target.operation === "assist_get") return {method: "GET", path: `/api/agent/assists/${target.id}`};
  fail();
}

function bodyFor(target, input) {
  if (reads.includes(target.operation)) return undefined;
  if (target.operation === "execute") {
    if (input.payment_signature !== undefined && (typeof input.payment_signature !== "string" || input.payment_signature.length < 1 || input.payment_signature.length > 65536)) fail();
    return JSON.stringify(input.payment_signature === undefined ? {} : {payment_signature: input.payment_signature});
  }
  if (!object(input.args)) fail();
  return JSON.stringify({kind: prepares[target.operation], args: input.args});
}

// This is a reviewable message for an external EOA personal_sign implementation.
// It contains no private key and is never a local signing request.
export function prepareWalletRequest(base, target, input, now = Math.floor(Date.now() / 1000), nonce = randomBytes(16).toString("hex")) {
  const expected = ["receipt", "wallet_address", ...(target.operation in prepares ? ["args"] : target.operation === "execute" && input.payment_signature !== undefined ? ["payment_signature"] : [])];
  if (!exactKeys(input, expected) || !walletPattern.test(input.wallet_address) ||
      typeof input.receipt !== "string" || input.receipt.length > 32768 || !/^[A-Za-z0-9_.-]+$/.test(input.receipt)) fail();
  return unsignedRequest(base, targetFor(target), bodyFor(target, input), input.receipt, input.wallet_address, now, now + 120, nonce);
}

function unsignedRequest(base, target, body, receipt, address, created, expires, nonce) {
  const headers = {"x-siwa-receipt": receipt, "x-key-id": address, "x-timestamp": String(created), "x-agent-wallet-address": address, "x-agent-chain-id": "8453"};
  const covered = [...components];
  if (body !== undefined) {
    headers["content-digest"] = `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;
    covered.push("content-digest");
  }
  const params = `(${covered.map(c => `"${c}"`).join(" ")});created=${created};expires=${expires};nonce="${nonce}";keyid="${address}"`;
  headers["signature-input"] = `sig1=${params}`;
  const message = covered.map(c => `"${c}": ${c === "@method" ? target.method.toLowerCase() : c === "@path" ? target.path : headers[c]}`)
    .concat(`"@signature-params": ${params}`).join("\n");
  return {origin: walletOrigin(base), ...target, ...(body === undefined ? {} : {body}), headers, message};
}

export function signedWalletRequest(base, target, input, now = Math.floor(Date.now() / 1000)) {
  if (!exactKeys(input, ["request", "signature"]) || !/^0x[0-9a-fA-F]{130}$/.test(input.signature ?? "")) fail();
  const r = input.request;
  if (!object(r) || !object(r.headers)) fail();
  const {method, path} = targetFor(target);
  if (!exactKeys(r, ["origin", "method", "path", "headers", "message", ...(method === "POST" ? ["body"] : [])]) ||
      r.origin !== walletOrigin(base) || r.method !== method || r.path !== path) fail();
  if (method === "POST") {
    if (typeof r.body !== "string" || Buffer.byteLength(r.body) > 100000) fail();
    let body; try { body = JSON.parse(r.body); } catch { fail(); }
    if (target.operation in prepares) {
      if (!exactKeys(body, ["kind", "args"]) || body.kind !== prepares[target.operation] || !object(body.args)) fail();
    } else if (!object(body) || Object.keys(body).some(k => k !== "payment_signature") ||
      (body.payment_signature !== undefined && (typeof body.payment_signature !== "string" || body.payment_signature.length < 1 || body.payment_signature.length > 65536))) fail();
  }
  const receipt = r.headers["x-siwa-receipt"], address = r.headers["x-agent-wallet-address"];
  if (!walletPattern.test(address ?? "") || typeof receipt !== "string" || receipt.length > 32768 || !/^[A-Za-z0-9_.-]+$/.test(receipt)) fail();
  const match = /;created=(\d+);expires=(\d+);nonce="([a-f0-9]{32})";keyid="(0x[a-f0-9]{40})"$/.exec(r.headers["signature-input"] ?? "");
  if (!match || match[4] !== address) fail();
  const created = Number(match[1]), expires = Number(match[2]);
  if (!Number.isSafeInteger(created) || expires !== created + 120 || created > now + 30 || expires <= now) fail();
  const expected = unsignedRequest(base, {method, path}, r.body, receipt, address, created, expires, match[3]);
  if (r.message !== expected.message || !exactKeys(r.headers, Object.keys(expected.headers)) ||
      Object.keys(expected.headers).some(k => expected.headers[k] !== r.headers[k])) fail();
  return {...r, headers: {...r.headers, signature: `sig1=:${Buffer.from(input.signature.slice(2), "hex").toString("base64")}:`}};
}

async function readInput(timeoutMs) {
  if (process.stdin.isTTY) fail();
  const stream = process.stdin;
  return new Promise((resolve, reject) => {
    let chunks = [], bytes = 0;
    const finish = (error, value) => {
      clearTimeout(timer); stream.removeListener("data", data); stream.removeListener("end", end); stream.removeListener("error", failed); stream.pause(); chunks = [];
      error ? reject(error) : resolve(value);
    };
    const failed = () => finish(new UsageError("Pipe a valid wallet JSON object on stdin (maximum 200 KB)."));
    const data = chunk => { bytes += Buffer.byteLength(chunk); if (bytes > 200000) return failed(); chunks.push(Buffer.from(chunk)); };
    const end = () => { try { const value = JSON.parse(Buffer.concat(chunks).toString("utf8")); if (!object(value)) return failed(); finish(null, value); } catch { failed(); } };
    const timer = setTimeout(failed, timeoutMs);
    stream.on("data", data); stream.once("end", end); stream.once("error", failed); stream.resume();
  });
}

function recovery(request) {
  const match = /^\/api\/agent\/payment_intents\/([0-9a-f-]+)\/execute$/.exec(request.path);
  return {outcome_unknown: true, recovery_required: true,
    ...(match ? {payment_intent_id: match[1], status_url: new URL(`/api/agent/payment_intents/${match[1]}`, request.origin).href} : {}),
    next_action: "Do not pay again. Recover the existing intent with a fresh signed GET."};
}

async function send(request, timeoutMs, outcomeUnknown = false) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once("SIGINT", interrupt); process.once("SIGTERM", interrupt);
  try {
    const response = await fetch(new URL(request.path, request.origin), {
      method: request.method, headers: {accept: "application/json", ...request.headers, ...(request.body === undefined ? {} : {"content-type": "application/json"})},
      body: request.body, credentials: "omit", redirect: "error", cache: "no-store", signal: AbortSignal.any([controller.signal, AbortSignal.timeout(timeoutMs)]),
    });
    const chunks = []; let bytes = 0;
    const reader = response.body?.getReader();
    if (!reader) throw new Error("invalid response");
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 1000000) { await reader.cancel(); throw new Error("oversized response"); }
      chunks.push(Buffer.from(value));
    }
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    // Never echo a receipt or HTTP proof reflected by a failed proxy.
    const text = JSON.stringify(body);
    const paymentProof = request.path.endsWith("/execute") ? JSON.parse(request.body ?? "{}").payment_signature : undefined;
    if ([request.headers["x-siwa-receipt"], request.headers.signature, paymentProof].some(proof => proof && text.includes(proof))) throw new Error("reflected proof");
    const known = {200: "applied", 202: "settled", 409: "settlement_pending", 402: "payment_required", 410: "expired"}[response.status];
    const uncertain = outcomeUnknown && request.path.endsWith("/execute") && (!known || body?.status !== known);
    return {ok: response.ok && !uncertain, status: response.status, body,
      ...(uncertain ? recovery(request) : {}),
      ...(response.headers.has("payment-required") ? {payment_required: response.headers.get("payment-required")} : {}),
      ...(response.headers.has("payment-response") ? {payment_response: response.headers.get("payment-response")} : {})};
  } catch {
    return {ok: false, status: null, ...(outcomeUnknown ? recovery(request) : {}), error: {code: controller.signal.aborted ? "aborted" : "wallet_request_unavailable", outcome_unknown: outcomeUnknown,
      message: "Request was not retried. Recover an existing intent with payments get and a fresh signed envelope; do not create another payment."}};
  } finally {
    process.removeListener("SIGINT", interrupt); process.removeListener("SIGTERM", interrupt);
  }
}

export async function requestWallet(base, target, timeoutMs) {
  if (["nonce", "verify"].includes(target.operation)) {
    const origin = walletOrigin(target.siwaUrl); // Always explicit, never an ambient secret destination.
    if (target.phase !== "send") fail();
    let body;
    if (target.operation === "nonce") {
      if (!walletPattern.test(target.walletAddress ?? "")) fail();
      body = {wallet_address: target.walletAddress, chain_id: 8453, audience: "patchbay"};
    } else {
      body = await readInput(timeoutMs);
      if (!exactKeys(body, ["wallet_address", "chain_id", "audience", "nonce", "message", "signature"]) ||
          !walletPattern.test(body.wallet_address ?? "") || body.chain_id !== 8453 || body.audience !== "patchbay" ||
          !/^[a-f0-9]{32}$/.test(body.nonce ?? "") || typeof body.message !== "string" || body.message.length > 2048 ||
          !/^0x[0-9a-fA-F]{130}$/.test(body.signature ?? "")) fail();
    }
    return send({origin, path: `/api/shared/siwa/wallet/${target.operation}`, method: "POST", headers: {}, body: JSON.stringify(body)}, timeoutMs);
  }
  const input = await readInput(timeoutMs);
  if (target.phase === "prepare") return {ok: true, request: prepareWalletRequest(base, target, input)};
  return send(signedWalletRequest(base, target, input), timeoutMs, !reads.includes(target.operation));
}
