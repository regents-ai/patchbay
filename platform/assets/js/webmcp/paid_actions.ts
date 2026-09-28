import {loadPrivyBridge, privyAppId} from "../privy/account.ts";
import type {MetaDocument} from "../privy/account.ts";
import {failure, signStep} from "../wallet_actions/sign_step.ts";
import type {SelectedWallet, SignatureStep, StepChain} from "../wallet_actions/sign_step.ts";

const INTENTS_PATH = "/api/payment_intents";
const RESPONSE_HEADER = "payment-response";
const SIGNED_REPLAY_LIMIT = 3;

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

/** Privy's active wallet, or why there is none to sign with. */
export type PaymentWallet = {ok: true; wallet: SelectedWallet} | Refusal;

export type PayOptions = {
  fetch?: PaymentFetch;
  csrfToken?: string;
  document?: Document;
  signal?: AbortSignal;
  wallet?: (doc: Document, signal?: AbortSignal) => Promise<PaymentWallet>;
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
  paymentResponse: string | null;
};

// What Patchbay wrote for the page's wallet to sign, as its 402 answer
// carries it: one signature step, for one signer, on one chain.
type WalletReview = {id: string; signer: string; chain: StepChain; steps?: SignatureStep[]};

/**
 * Pays for one action end to end with the account's own wallet: creates the
 * payment intent, asks Patchbay to execute it from Privy's active wallet, and
 * when Patchbay answers with what that wallet is to sign, has the wallet sign
 * exactly that and sends back the signature alone.
 *
 * Patchbay writes what is signed, for one wallet on the account: the amount,
 * the recipient, the asset and the chain all come from the stored intent.
 * Nothing here builds or changes any of it. Every call reaches the wallet;
 * a second call signs its own intent.
 *
 * Answers with Patchbay's last word as `{status, body}`, together with the
 * intent as it was created. When the wallet cannot sign, or does not, the
 * unsigned answer comes back and `unsigned` names why.
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

    const found = await (options.wallet ?? bridgeWallet)(options.document ?? globalThis.document, signal);
    if (signal?.aborted) return canceled();

    const executePath = `${INTENTS_PATH}/${encodeURIComponent(intent!.id)}/execute`;
    const offered = await request(options, executePath, {
      method: "POST",
      json: {active_wallet: found.ok ? found.wallet.address : null},
    });
    if (signal?.aborted) return canceled();
    if (offered.status !== 402) return answer(offered, intent);
    if (!found.ok) return answer(offered, intent, found.reason);
    const {wallet} = found;

    const review = offered.body?.review as WalletReview | undefined;
    const step = review?.steps?.find(one => one.kind === "signature");
    if (!review || !step) return answer(offered, intent, offered.body!.problem_code as string | undefined);

    let signing = false;
    let signature: string;
    try {
      signature = await signStep(review.chain, review.signer, step, () => wallet, () => { signing = true; });
    } catch (error) {
      if (signal?.aborted) return canceled();
      return answer(offered, intent, failure(signing, error));
    }
    if (signal?.aborted) return canceled();

    const signed = {active_wallet: wallet.address, review_id: review.id, signature};
    submitted = true;
    let settled = await request(options, executePath, {method: "POST", json: signed});
    if (signal?.aborted) return canceled();

    // An unclear 5xx after signing may mean the facilitator already saw the
    // payment. Replay the same intent and the same signature only.
    for (let attempt = 1; shouldReplaySigned(settled) && attempt < SIGNED_REPLAY_LIMIT; attempt += 1) {
      settled = await request(options, executePath, {method: "POST", json: signed});
      if (signal?.aborted) return canceled();
    }

    const knownOutcome = {
      200: "applied", 202: "settled", 409: "settlement_pending",
      402: "payment_required", 410: "expired",
    }[settled.status];
    if (!knownOutcome || settled.body?.status !== knownOutcome) {
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
    body: {
      problem_code: "canceled",
      outcome: dispatched ? "unknown" : "canceled",
      payment_intent_id: intent?.id ?? null,
      status_url: intent?.id ? `${INTENTS_PATH}/${encodeURIComponent(intent.id)}` : null,
      error: submitted
        ? "Canceled after signed submission began. Payment may have settled; cancellation does not reverse it."
        : "The payment call was canceled. An issued server request or wallet prompt may still finish.",
      next_action: intent?.id
        ? "Read this intent's status before taking another payment action. Do not pay again automatically."
        : "Check the current page before retrying. No payment intent ID was returned.",
    },
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

// Privy's active wallet, reached through the same Privy bridge the account
// strip uses.
async function bridgeWallet(doc: MetaDocument, signal?: AbortSignal): Promise<PaymentWallet> {
  const appId = privyAppId(doc);
  if (!appId) return {ok: false, reason: "unconfigured"};

  const bridge = await loadPrivyBridge(doc);
  if (signal?.aborted) return {ok: false, reason: "canceled"};
  if (!bridge) return {ok: false, reason: "unloadable"};

  return bridge.activeWallet(appId);
}

async function request(
  options: PayOptions,
  url: string,
  {method, json}: {method: string; json?: unknown},
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
      },
      body: json === undefined ? undefined : JSON.stringify(json),
    });

    return {
      status: response.status ?? 0,
      body: await readBody(response),
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
    body: {error: problem, problem_code: "unreachable"},
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
