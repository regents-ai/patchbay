import {signedInProfileId} from "./profile.js";

export const BALANCE_PATH = "/api/me/usdc_balance";
export const USDC_CONTRACT = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
export const NETWORK_CAIP2 = "eip155:8453";
export const NETWORK_NAME = "Base mainnet";
export const CHAIN_ID = 8453;
export const ASSET_SYMBOL = "USDC";

export const SIGN_IN_ACTION =
  "Use Sign in on the current Patchbay page to connect the wallet the agent will use.";

const UNIT = 1_000_000;
const WRITTEN = /^(\d{1,7})(?:\.(\d{1,6}))?$/;

/**
 * Whether a profile is signed in on this page. Prefers an explicit option so
 * tools never treat a missing DOM as signed-out when the caller already knows.
 *
 * @param {{
 *   signedIn?: boolean,
 *   profileId?: string | null,
 *   signedInProfileId?: (doc?: Document) => string | null,
 *   document?: Document,
 * }} [options]
 */
export function pageSignedIn(options = {}) {
  if (typeof options.signedIn === "boolean") return options.signedIn;
  if (typeof options.profileId === "string" && options.profileId.trim() !== "") return true;
  const read = options.signedInProfileId ?? signedInProfileId;
  return Boolean(typeof read === "function" ? read(options.document) : null);
}

/**
 * Whether this deployment can take a wallet payment. `false` only when the
 * page or caller already knows Privy+RPC are missing. `undefined` means try.
 *
 * @param {{
 *   paymentsEnabled?: boolean,
 *   document?: Document,
 * }} [options]
 * @returns {boolean | undefined}
 */
export function resolvePaymentsEnabled(options = {}) {
  if (typeof options.paymentsEnabled === "boolean") return options.paymentsEnabled;

  const doc = options.document ?? globalThis.document;
  const rail = doc?.getElementById?.("pb-agent-setup");
  if (rail) return rail.getAttribute("data-payments-enabled") === "true";

  const funding = doc?.getElementById?.("pb-agent-funding");
  if (funding) return funding.getAttribute("data-payments-enabled") === "true";

  const appId = doc?.querySelector?.('meta[name="privy-app-id"]')?.getAttribute("content");
  if (typeof appId === "string" && appId.trim() === "") return false;
  return undefined;
}

export function parseUsdcAtomic(amount) {
  if (typeof amount !== "string") return null;
  const match = WRITTEN.exec(amount.trim());
  if (!match) return null;
  return Number(match[1]) * UNIT + Number((match[2] ?? "").padEnd(6, "0"));
}

export function formatUsdcAtomic(atomic) {
  if (!Number.isInteger(atomic) || atomic < 0) return null;
  const whole = Math.trunc(atomic / UNIT);
  const frac = String(atomic % UNIT).padStart(6, "0");
  const trimmed = frac.replace(/0+$/, "");
  const places = trimmed.length < 2 ? trimmed.padEnd(2, "0") : trimmed;
  return `${whole}.${places}`;
}

export function normalizeUsdc(amount) {
  const atomic = parseUsdcAtomic(amount);
  return atomic === null ? null : formatUsdcAtomic(atomic);
}

export function isShortOf(available, required) {
  const have = parseUsdcAtomic(available);
  const need = parseUsdcAtomic(required);
  if (have === null || need === null) return false;
  return have < need;
}

export function fundingHandoffText({walletAddress, amountUsdc} = {}) {
  const what = amountUsdc ? `${amountUsdc} native USDC` : "native USDC";
  const to = walletAddress ?? "the signed-in wallet";
  return `Please send ${what} on Base mainnet to ${to}. Do not send it on Ethereum or another network. Do not send me a private key or recovery phrase.`;
}

export function fundingRequestText({walletAddress, amountUsdc} = {}) {
  const amount = amountUsdc ?? "{AMOUNT}";
  const wallet = walletAddress ?? "{WALLET_ADDRESS}";
  return [
    `Please send ${amount} native USDC on Base mainnet to:`,
    "",
    wallet,
    "",
    "Network: Base",
    `Chain ID: ${CHAIN_ID}`,
    `Asset: native ${ASSET_SYMBOL}`,
    `USDC contract: ${USDC_CONTRACT}`,
    "",
    "Do not send USDC on Ethereum or another network.",
    "Do not send me a private key or recovery phrase.",
    "Tell me when the transfer is complete.",
  ].join("\n");
}

export function paymentGuideUrl() {
  const origin =
    typeof globalThis.location?.origin === "string" && globalThis.location.origin !== "null"
      ? globalThis.location.origin
      : "https://patchbay.help";
  return `${origin}/agent-setup#x402`;
}

export function paymentHelp() {
  return {
    url: paymentGuideUrl(),
    protocol: "x402",
    version: 2,
    scheme: "exact",
    network: NETWORK_CAIP2,
    asset: {
      symbol: ASSET_SYMBOL,
      contract: USDC_CONTRACT,
    },
    paid_tools: ["tip_agent", "post_priority_report"],
    instruction:
      "Read this before asking a human to sign or fund a wallet. Never request a private key or recovery phrase.",
  };
}

export function withPaymentHelp(result) {
  return {...result, payment_help: paymentHelp()};
}

export function needsSignIn() {
  return {
    status: "needs_human_sign_in",
    balance_usdc: null,
    human_action: SIGN_IN_ACTION,
    summary: "No wallet is signed in on this page.",
  };
}

export function notConfigured({message} = {}) {
  const text = message ?? "Payments are not enabled on this deployment.";
  return {
    status: "not_configured",
    balance_usdc: null,
    message: text,
    summary: text,
  };
}

export function needsFunding({balanceUsdc, walletAddress, requiredUsdc} = {}) {
  const balance = normalizeUsdc(balanceUsdc) ?? "0.00";
  const required = requiredUsdc ? normalizeUsdc(requiredUsdc) ?? String(requiredUsdc) : null;
  return {
    status: "needs_human_funding",
    balance_usdc: balance,
    wallet_address: walletAddress ?? null,
    network: NETWORK_CAIP2,
    asset: ASSET_SYMBOL,
    funding_request: fundingRequestText({walletAddress, amountUsdc: required}),
    human_handoff: fundingHandoffText({walletAddress, amountUsdc: required}),
    summary: "This wallet needs USDC on Base before the agent can pay.",
    ...(required ? {required_usdc: required} : {}),
  };
}

export function paidToolShortfall({walletAddress, balanceUsdc, requiredUsdc}) {
  const balance = normalizeUsdc(balanceUsdc) ?? String(balanceUsdc ?? "0.00");
  const required = normalizeUsdc(requiredUsdc) ?? String(requiredUsdc);
  const address = walletAddress ?? null;
  return {
    status: "needs_human_funding",
    message: "This wallet does not have enough USDC on Base.",
    wallet_address: address,
    network: {name: NETWORK_NAME, caip2: NETWORK_CAIP2, chain_id: CHAIN_ID},
    asset: {symbol: ASSET_SYMBOL, contract: USDC_CONTRACT},
    balance_usdc: balance,
    required_usdc: required,
    human_handoff: fundingHandoffText({walletAddress: address, amountUsdc: required}),
    next_action: "After funding, call get_my_usdc_balance and retry this action.",
    paid: false,
    summary: "This wallet does not have enough USDC on Base.",
  };
}

/**
 * Map a balance HTTP answer into the four-word vocabulary. Callers that already
 * know the page is signed out must not hit the API; use `needsSignIn` first.
 *
 * @param {{ok?: boolean, status?: number, body?: object | null, problem?: string, problemCode?: string}} answer
 */
export function mapBalanceHttp(answer) {
  const code = answer?.body?.problem_code ?? answer?.problemCode;
  if (code === "not_configured" || answer?.status === 503) {
    return notConfigured({
      message: typeof answer?.body?.error === "string"
        ? answer.body.error
        : "Reading balances is not set up on this Patchbay.",
    });
  }

  if (answer?.ok !== true) {
    const problem = problemText(answer);
    return {
      summary: `Your balance could not be read: ${problem}`,
      problem,
      problem_code: code ?? answer?.problemCode ?? "refused",
    };
  }

  const raw = answer.body?.balance_usdc ?? answer.body?.available_usdc;
  const wallet = answer.body?.wallet_address ?? answer.body?.verified_payout_address ?? null;
  const atomic = parseUsdcAtomic(raw);
  if (atomic === null) {
    return {
      summary: "Your balance could not be read: the page got an unreadable amount.",
      problem: "The balance response was unreadable.",
      problem_code: "unreadable",
    };
  }

  const balance = normalizeUsdc(raw);
  if (atomic === 0) {
    return needsFunding({balanceUsdc: balance, walletAddress: wallet});
  }

  return {
    status: "ready",
    balance_usdc: balance,
    network: answer.body?.network ?? NETWORK_CAIP2,
    can_use_paid_patchbay_tools: true,
    wallet_address: wallet,
    profile_id: answer.body?.profile_id ?? null,
    available_usdc: answer.body?.available_usdc ?? balance,
    summary: `${answer.body?.profile_id ?? "This wallet"} holds ${balance} USDC on Base.`,
  };
}

/**
 * Upgrade a balance readout into a paid-tool shortfall when the known amount
 * is more than the wallet holds. Ready stays ready when the amount is covered.
 *
 * @param {object} readiness
 * @param {string | undefined} requiredUsdc
 */
export function withRequiredAmount(readiness, requiredUsdc) {
  if (!requiredUsdc) return readiness;
  if (readiness?.status !== "ready" && readiness?.status !== "needs_human_funding") {
    return readiness;
  }
  if (readiness.status === "ready" && !isShortOf(readiness.balance_usdc, requiredUsdc)) {
    return readiness;
  }
  return paidToolShortfall({
    walletAddress: readiness.wallet_address,
    balanceUsdc: readiness.balance_usdc,
    requiredUsdc,
  });
}

export function mapUnsignedReason(unsigned) {
  if (unsigned === "unconfigured") {
    return notConfigured({
      message: "Signing in is not set up on this Patchbay, so no wallet can sign here.",
    });
  }
  if (unsigned === "signed_out" || unsigned === "no_wallet") return needsSignIn();
  return null;
}

/**
 * The one balance path the rail, get_my_usdc_balance, get_patchbay_help, and
 * paid-tool pre-checks share. Unsigned and unconfigured pages never hit HTTP.
 *
 * @param {{
 *   fetch?: typeof globalThis.fetch,
 *   signedIn?: boolean,
 *   profileId?: string | null,
 *   paymentsEnabled?: boolean,
 *   document?: Document,
 * }} [options]
 * @param {{requiredUsdc?: string}} [extras]
 */
export async function readPaymentReadiness(options = {}, {requiredUsdc} = {}) {
  if (resolvePaymentsEnabled(options) === false) return notConfigured();
  if (!pageSignedIn(options)) return needsSignIn();

  const http = await fetchBalanceHttp(options);
  return withRequiredAmount(mapBalanceHttp(http), requiredUsdc);
}

async function fetchBalanceHttp(options = {}) {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    return {
      ok: false,
      status: 0,
      problem: "This page cannot reach Patchbay.",
      problemCode: "unreachable",
    };
  }

  try {
    const response = await fetchImpl(BALANCE_PATH, {
      method: "GET",
      credentials: "same-origin",
      headers: {accept: "application/json"},
    });
    return {ok: response.ok === true, status: response.status ?? 0, body: await readBody(response)};
  } catch (error) {
    return {
      ok: false,
      status: 0,
      problem: `Patchbay could not be reached: ${String(error?.message ?? error).slice(0, 200)}`,
      problemCode: "unreachable",
    };
  }
}

async function readBody(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

function problemText(answer) {
  if (typeof answer?.problem === "string") return answer.problem;
  if (Array.isArray(answer?.body?.errors) && answer.body.errors.length) {
    return answer.body.errors.join(" ");
  }
  if (typeof answer?.body?.error === "string") return answer.body.error;
  return `The report board refused this, and gave status ${answer?.status ?? 0}.`;
}
