import {errorIn, refusal} from "../api_error.ts";
import {loadPrivyBridge, privyAppId} from "../privy/account.ts";
import type {MetaDocument} from "../privy/account.ts";

const INTENTS_PATH = "/api/payment_intents";
const CHALLENGE_HEADER = "payment-required";
const SIGNATURE_HEADER = "payment-signature";
const RESPONSE_HEADER = "payment-response";
const X402_VERSION = 2;
const EVM_NETWORK = /^eip155:(\d+)$/;
const SIGNED_REPLAY_LIMIT = 3;

// The EIP-3009 authorization USDC accepts, in the exact shape the server
// checks: one transfer from the signer to the recipient the challenge names.
const PRIMARY_TYPE = "TransferWithAuthorization";
const TRANSFER_TYPES = {
  EIP712Domain: [
    {name: "name", type: "string"},
    {name: "version", type: "string"},
    {name: "chainId", type: "uint256"},
    {name: "verifyingContract", type: "address"},
  ],
  [PRIMARY_TYPE]: [
    {name: "from", type: "address"},
    {name: "to", type: "address"},
    {name: "value", type: "uint256"},
    {name: "validAfter", type: "uint256"},
    {name: "validBefore", type: "uint256"},
    {name: "nonce", type: "bytes32"},
  ],
};

export type PaymentRequestInit = {
  signal?: AbortSignal;
  method: string;
  credentials: RequestCredentials;
  headers: Record<string, string>;
  body?: string;
};

export type PaymentResponse = {
  status?: number;
  json(): Promise<unknown>;
  headers?: {get?(name: string): string | null};
};

export type PaymentFetch = (url: string, init: PaymentRequestInit) => Promise<PaymentResponse>;

// A JSON answer from Patchbay, read as a bag of named fields.
type PaymentBody = Record<string, unknown>;

export type PaymentIntent = {id: string; [field: string]: unknown};

type Refusal = {ok: false; reason: string};

export type PaymentSigner =
  | {
      ok: true;
      address: string;
      signTypedData: (typedData: TransferAuthorization) => Promise<{ok: true; signature: string} | Refusal>;
    }
  | Refusal;

export type PayOptions = {
  fetch?: PaymentFetch;
  csrfToken?: string;
  document?: Document;
  signal?: AbortSignal;
  signer?: (doc: Document, signal?: AbortSignal) => Promise<PaymentSigner>;
};

export type PayOutcome = {
  status: number;
  body: PaymentBody | null;
  intent?: PaymentIntent;
  unsigned?: string;
};

type HttpAnswer = {
  status: number;
  body: PaymentBody | null;
  challenge: string | null;
  paymentResponse: string | null;
};

// One x402 payment requirement, as the challenge names it.
type PaymentRequirement = {
  scheme?: string;
  network?: string;
  asset: string;
  payTo: string;
  amount: string;
  maxTimeoutSeconds: number;
  extra: {name: string; version: string};
};

type PaymentChallenge = {accepts?: PaymentRequirement[]; extensions?: unknown};

type TransferAuthorization = ReturnType<typeof transferAuthorization>;

/**
 * Pays for one action end to end: creates the payment intent, asks Patchbay to
 * execute it, and when Patchbay answers with a payment challenge, signs the
 * USDC authorization that challenge names with the wallet signed in on this
 * page and asks again with the signature attached.
 *
 * Every figure in what is signed is taken from the challenge Patchbay sent:
 * the amount, the recipient wallet, the asset and the chain. Nothing here can
 * sign for a different amount or recipient than the challenge names.
 *
 * Answers with Patchbay's last word as `{status, body}`, together with the
 * intent as it was created. When no wallet can sign, or the wallet refuses,
 * the challenge answer comes back untouched and `unsigned` names why.
 */
export async function payForIntent(options: PayOptions, {kind, args}: {kind: string; args: object}): Promise<PayOutcome> {
  const signal = options.signal;
  let intent: PaymentIntent | undefined;
  let dispatched = false;
  let submitted = false;
  const canceled = () => paymentCancellation(intent, {dispatched, submitted});
  if (signal?.aborted) return canceled();
  try {
    dispatched = true;
    const created = await request(options, INTENTS_PATH, {method: "POST", json: {kind, args}});
    if (created.status === 201) intent = created.body as PaymentIntent;
    if (signal?.aborted) return canceled();
    if (created.status !== 201) return answer(created);

    const executePath = `${INTENTS_PATH}/${encodeURIComponent(intent!.id)}/execute`;
    const challenged = await request(options, executePath, {method: "POST"});
    if (signal?.aborted) return canceled();
    if (challenged.status !== 402) return answer(challenged, intent);

    const challenge = decodeChallenge(challenged.challenge);
    const requirement = challenge?.accepts?.[0];
    const chainId = chainIdOf(requirement);
    if (chainId === null) return answer(challenged, intent, "unsupported_challenge");

    const signer = await (options.signer ?? bridgeSigner)(options.document ?? globalThis.document, signal);
    if (signal?.aborted) return canceled();
    if (!signer.ok) return answer(challenged, intent, signer.reason);

    const typedData = transferAuthorization(requirement!, chainId, signer.address);
    const signed = await signer.signTypedData(typedData);
    if (signal?.aborted) return canceled();
    if (!signed.ok) return answer(challenged, intent, signed.reason);

    const payment = {
      x402Version: X402_VERSION,
      accepted: requirement,
      payload: {signature: signed.signature, authorization: typedData.message},
      extensions: challenge!.extensions,
    };
    const signedHeaders: Record<string, string> = {[SIGNATURE_HEADER]: encodeBase64Json(payment)};
    submitted = true;
    let settled = await request(options, executePath, {
      method: "POST",
      headers: signedHeaders,
    });

    if (signal?.aborted) return canceled();

    // An unclear 5xx after signing may mean the facilitator already saw the
    // payment. Replay the same intent and the same signature only.
    for (let attempt = 1; shouldReplaySigned(settled) && attempt < SIGNED_REPLAY_LIMIT; attempt += 1) {
      settled = await request(options, executePath, {method: "POST", headers: signedHeaders});
      if (signal?.aborted) return canceled();
    }

    // A payment that was applied, settled or challenged says so in its
    // status; one that was refused says so in its error's code.
    const knownOutcome = {
      200: "applied", 202: "settled", 409: "settlement_pending",
      402: "payment_required", 410: "expired",
    }[settled.status];
    const said = settled.status === 409 || settled.status === 410
      ? errorIn(settled.body)?.code
      : settled.body?.status;
    if (!knownOutcome || said !== knownOutcome) {
      return {
        status: settled.status,
        body: {
          ...(settled.body ?? {}),
          payment_intent_id: intent!.id,
          outcome: "unknown",
          recovery_required: true,
          status_url: `${INTENTS_PATH}/${encodeURIComponent(intent!.id)}`,
          next_action: "Do not pay again; check this intent.",
        },
        intent,
      };
    }

    return answer(settled, intent);
  } catch (error) {
    if (signal?.aborted) return canceled();
    throw error;
  }
}

export function paymentCancellation(
  intent?: PaymentIntent,
  {dispatched = false, submitted = false}: {dispatched?: boolean; submitted?: boolean} = {},
) {
  return {
    status: 0,
    ...(intent && {intent}),
    body: refusal(
      "canceled",
      submitted
        ? "Canceled after signed submission began. Payment may have settled; cancellation does not reverse it."
        : "The payment call was canceled. An issued server request or wallet prompt may still finish.",
      intent?.id
        ? "Read this intent's status before taking another payment action. Do not pay again automatically."
        : "Check the current page before retrying. No payment intent ID was returned.",
      {
        outcome: dispatched ? "unknown" : "canceled",
        payment_intent_id: intent?.id ?? null,
        status_url: intent?.id ? `${INTENTS_PATH}/${encodeURIComponent(intent.id)}` : null,
      },
    ),
  };
}

export function shouldReplaySigned(
  {status, paymentResponse}: {status?: number; paymentResponse?: string | null} = {},
): boolean {
  return Number.isInteger(status) && status! >= 500 && status! <= 599 && !paymentResponse;
}

function answer({status, body}: HttpAnswer, intent?: PaymentIntent, unsigned?: string): PayOutcome {
  return {status, body, ...(intent && {intent}), ...(unsigned && {unsigned})};
}

// The wallet the page signed in with, reached through the same Privy bridge
// the account strip uses. It answers the signing address first, because the
// authorization names its signer before it is signed.
async function bridgeSigner(doc: MetaDocument, signal?: AbortSignal): Promise<PaymentSigner> {
  const appId = privyAppId(doc);
  if (!appId) return {ok: false, reason: "unconfigured"};

  const bridge = await loadPrivyBridge(doc);
  if (signal?.aborted) return {ok: false, reason: "canceled"};
  if (!bridge) return {ok: false, reason: "unloadable"};

  const wallet = await bridge.walletAddress(appId);
  if (!wallet.ok) return wallet;

  return {
    ok: true,
    address: wallet.address,
    signTypedData: typedData => bridge.signTypedData(appId, typedData),
  };
}

// Only an exact-scheme requirement on an EVM chain can be signed here; the
// chain id is the number after "eip155:" in the requirement's network.
function chainIdOf(requirement: PaymentRequirement | undefined): number | null {
  if (requirement?.scheme !== "exact") return null;
  const match = EVM_NETWORK.exec(requirement.network ?? "");
  return match ? Number(match[1]) : null;
}

function transferAuthorization(requirement: PaymentRequirement, chainId: number, from: string) {
  const nowSeconds = Math.floor(Date.now() / 1000);

  return {
    types: TRANSFER_TYPES,
    primaryType: PRIMARY_TYPE,
    domain: {
      name: requirement.extra.name,
      version: requirement.extra.version,
      chainId,
      verifyingContract: requirement.asset,
    },
    message: {
      from,
      to: requirement.payTo,
      value: requirement.amount,
      validAfter: "0",
      validBefore: String(nowSeconds + requirement.maxTimeoutSeconds),
      nonce: randomNonce(),
    },
  };
}

function randomNonce() {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(32));
  return `0x${Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("")}`;
}

function decodeChallenge(header: string | null): PaymentChallenge | null {
  if (typeof header !== "string" || header === "") return null;

  try {
    const bytes = Uint8Array.from(atob(header), char => char.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

function encodeBase64Json(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(""));
}

async function request(
  options: PayOptions,
  url: string,
  {method, json, headers = {}}: {method: string; json?: unknown; headers?: Record<string, string>},
): Promise<HttpAnswer> {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") return unreachable("This page cannot reach Patchbay.");

  try {
    const response = await fetchImpl(url, {
      signal: options.signal,
      method,
      credentials: "same-origin",
      headers: {
        accept: "application/json",
        "x-csrf-token": options.csrfToken ?? "",
        ...(json === undefined ? {} : {"content-type": "application/json"}),
        ...headers,
      },
      body: json === undefined ? undefined : JSON.stringify(json),
    });

    return {
      status: response.status ?? 0,
      body: await readBody(response),
      challenge: response.headers?.get?.(CHALLENGE_HEADER) ?? null,
      paymentResponse: response.headers?.get?.(RESPONSE_HEADER) ?? null,
    };
  } catch (error) {
    return unreachable(
      `Patchbay could not be reached: ${String((error as {message?: unknown} | null | undefined)?.message ?? error).slice(0, 200)}`,
    );
  }
}

function unreachable(problem: string): HttpAnswer {
  return {
    status: 0,
    body: refusal("unreachable", problem, "Check the page is open and online, then try again."),
    challenge: null,
    paymentResponse: null,
  };
}

async function readBody(response: PaymentResponse): Promise<PaymentBody | null> {
  try {
    return (await response.json()) as PaymentBody | null;
  } catch {
    return null;
  }
}
