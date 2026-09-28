import {signedInProfileId} from "./profile.ts";

export const BALANCE_PATH = "/api/me/regents_balance";
export const USDC_CONTRACT = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
export const NETWORK_CAIP2 = "eip155:8453";
export const CHAIN_ID = 8453;
export const ASSET_SYMBOL = "USDC";

export const SIGN_IN_ACTION =
  "Use Sign in on the current Patchbay page to connect the wallet the agent will use.";

const UNIT = 1_000_000;
const WRITTEN = /^(\d{1,7})(?:\.(\d{1,6}))?$/;

export type ReadinessOptions = {
  fetch?: typeof globalThis.fetch;
  signal?: AbortSignal;
  signedIn?: boolean;
  profileId?: string | null;
  signedInProfileId?: (doc?: Document) => string | null;
  paymentsEnabled?: boolean;
  document?: Document;
};

// What `GET /api/me/regents_balance` answers with. The fields this file checks
// before use are left unknown; the rest are passed on as the server wrote them.
type BalanceBody = {
  problem_code?: string;
  error?: unknown;
  errors?: unknown;
  balance_usdc?: unknown;
  available_usdc?: unknown;
  wallet_address?: string | null;
  verified_payout_address?: string | null;
  network?: string;
  profile_id?: string | null;
};

type BalanceAnswer = {
  ok?: boolean;
  status?: number;
  body?: BalanceBody | null;
  problem?: string;
  problemCode?: string;
};

export type NeedsSignIn = {
  status: "needs_human_sign_in";
  balance_usdc: null;
  human_action: string;
  summary: string;
};

export type NotConfigured = {
  status: "not_configured";
  balance_usdc: null;
  message: string;
  summary: string;
};

export type NeedsFunding = {
  status: "needs_human_funding";
  balance_usdc: string;
  wallet_address: string | null;
  network: string;
  asset: string;
  funding_request: string;
  human_handoff: string;
  summary: string;
};

export type BalanceUnread = {
  status?: undefined;
  summary: string;
  problem: string;
  problem_code: string;
};

export type Ready = {
  status: "ready";
  balance_usdc: string | null;
  network: string;
  can_use_paid_patchbay_tools: true;
  wallet_address: string | null;
  profile_id: string | null;
  available_usdc: unknown;
  summary: string;
};

export type BalanceReadout = NotConfigured | BalanceUnread | NeedsFunding | Ready;

export type PaymentReadiness = NeedsSignIn | BalanceReadout;

/**
 * Whether a profile is signed in on this page. Prefers an explicit option so
 * tools never treat a missing DOM as signed-out when the caller already knows.
 */
export function pageSignedIn(options: ReadinessOptions = {}): boolean {
  if (typeof options.signedIn === "boolean") return options.signedIn;
  if (typeof options.profileId === "string" && options.profileId.trim() !== "") return true;
  const read = options.signedInProfileId ?? signedInProfileId;
  return Boolean(typeof read === "function" ? read(options.document) : null);
}

/**
 * Whether this deployment can take a wallet payment. `false` only when the
 * page or caller already knows Privy+RPC are missing. `undefined` means try.
 */
export function resolvePaymentsEnabled(options: ReadinessOptions = {}): boolean | undefined {
  if (typeof options.paymentsEnabled === "boolean") return options.paymentsEnabled;

  const doc = options.document ?? globalThis.document;
  const rail = doc?.getElementById?.("pb-agent-setup") ?? doc?.getElementById?.("pb-readiness");
  if (rail) return rail.getAttribute("data-payments-enabled") === "true";

  const funding = doc?.getElementById?.("pb-agent-funding");
  if (funding) return funding.getAttribute("data-payments-enabled") === "true";

  const appId = doc?.querySelector?.('meta[name="privy-app-id"]')?.getAttribute("content");
  if (typeof appId === "string" && appId.trim() === "") return false;
  return undefined;
}

export function parseUsdcAtomic(amount: unknown): number | null {
  if (typeof amount !== "string") return null;
  const match = WRITTEN.exec(amount.trim());
  if (!match) return null;
  return Number(match[1]) * UNIT + Number((match[2] ?? "").padEnd(6, "0"));
}

export function formatUsdcAtomic(atomic: number): string | null {
  if (!Number.isInteger(atomic) || atomic < 0) return null;
  const whole = Math.trunc(atomic / UNIT);
  const frac = String(atomic % UNIT).padStart(6, "0");
  const trimmed = frac.replace(/0+$/, "");
  const places = trimmed.length < 2 ? trimmed.padEnd(2, "0") : trimmed;
  return `${whole}.${places}`;
}

export function normalizeUsdc(amount: unknown): string | null {
  const atomic = parseUsdcAtomic(amount);
  return atomic === null ? null : formatUsdcAtomic(atomic);
}

export function fundingHandoffText({walletAddress}: {walletAddress?: string | null} = {}): string {
  const to = walletAddress ?? "the signed-in wallet";
  return `Please send native USDC on Base mainnet to ${to}. Do not send it on Ethereum or another network. Do not send me a private key or recovery phrase.`;
}

export function fundingRequestText({walletAddress}: {walletAddress?: string | null} = {}): string {
  const wallet = walletAddress ?? "{WALLET_ADDRESS}";
  return [
    "Please send {AMOUNT} native USDC on Base mainnet to:",
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

export function withPaymentHelp<T extends object>(result: T): T & {payment_help: ReturnType<typeof paymentHelp>} {
  return {...result, payment_help: paymentHelp()};
}

export function needsSignIn(): NeedsSignIn {
  return {
    status: "needs_human_sign_in",
    balance_usdc: null,
    human_action: SIGN_IN_ACTION,
    summary: "No wallet is signed in on this page.",
  };
}

export function notConfigured({message}: {message?: string} = {}): NotConfigured {
  const text = message ?? "Payments are not enabled on this deployment.";
  return {
    status: "not_configured",
    balance_usdc: null,
    message: text,
    summary: text,
  };
}

export function needsFunding(
  {balanceUsdc, walletAddress}: {balanceUsdc?: string | null; walletAddress?: string | null} = {},
): NeedsFunding {
  return {
    status: "needs_human_funding",
    balance_usdc: normalizeUsdc(balanceUsdc) ?? "0.00",
    wallet_address: walletAddress ?? null,
    network: NETWORK_CAIP2,
    asset: ASSET_SYMBOL,
    funding_request: fundingRequestText({walletAddress}),
    human_handoff: fundingHandoffText({walletAddress}),
    summary: "This wallet needs USDC on Base before the agent can pay.",
  };
}

/**
 * Map a balance HTTP answer into the four-word vocabulary. Callers that already
 * know the page is signed out must not hit the API; use `needsSignIn` first.
 */
export function mapBalanceHttp(answer: BalanceAnswer): BalanceReadout {
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

export function mapUnsignedReason(unsigned: string | undefined): NotConfigured | NeedsSignIn | null {
  if (unsigned === "unconfigured") {
    return notConfigured({
      message: "Signing in is not set up on this Patchbay, so no wallet can sign here.",
    });
  }
  if (unsigned === "signed_out") return needsSignIn();
  return null;
}

/**
 * The one balance path the rail, get_my_regents_balance and get_patchbay_help
 * share. Unsigned and unconfigured pages never hit HTTP.
 */
export async function readPaymentReadiness(options: ReadinessOptions = {}): Promise<PaymentReadiness> {
  if (resolvePaymentsEnabled(options) === false) return notConfigured();
  if (!pageSignedIn(options)) return needsSignIn();

  return mapBalanceHttp(await fetchBalanceHttp(options));
}

async function fetchBalanceHttp(options: ReadinessOptions = {}): Promise<BalanceAnswer> {
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
      signal: options.signal,
      method: "GET",
      credentials: "same-origin",
      headers: {accept: "application/json"},
    });
    return {ok: response.ok === true, status: response.status ?? 0, body: await readBody(response)};
  } catch (error) {
    return {
      ok: false,
      status: 0,
      problem: `Patchbay could not be reached: ${String((error as {message?: unknown} | null | undefined)?.message ?? error).slice(0, 200)}`,
      problemCode: "unreachable",
    };
  }
}

async function readBody(response: Response): Promise<BalanceBody | null> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

function problemText(answer: BalanceAnswer): string {
  if (typeof answer?.problem === "string") return answer.problem;
  if (Array.isArray(answer?.body?.errors) && answer.body.errors.length) {
    return answer.body.errors.join(" ");
  }
  if (typeof answer?.body?.error === "string") return answer.body.error;
  return `The report board refused this, and gave status ${answer?.status ?? 0}.`;
}
