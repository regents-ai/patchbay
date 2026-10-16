import {signedInProfileId} from "./profile.ts";
import {fundingRequestText, readPaymentReadiness} from "./payment_readiness.ts";
import {getModelContext} from "./webmcpify.ts";

// The parts of a readiness answer the USDC Balance card reads.
type FundingReadiness = {
  status?: string;
  balance_usdc?: string | null;
  wallet_address?: string | null;
  funding_request?: string;
};

type MountOptions = {
  root?: Element | null;
  getModelContext?: () => unknown;
  signedInProfileId?: (doc?: Document) => string | null;
  fetch?: typeof globalThis.fetch;
  readPaymentReadiness?: typeof readPaymentReadiness;
};

/**
 * The WebMCP guide's status line. It says only whether the browser offers
 * WebMCP, never that Patchbay's tools reached an agent.
 */
export function webmcpLine(detected: boolean): {ok: boolean; text: string} {
  return detected
    ? {ok: true, text: "WebMCP detected in this browser"}
    : {ok: false, text: "WebMCP was not detected in this browser."};
}

/**
 * Paint the WebMCP guide's status line, and open the browser alternatives
 * when WebMCP is missing.
 */
export function mountWebMCPStatus(options: MountOptions = {}) {
  const root = options.root ?? globalThis.document?.getElementById("pb-webmcp-status");
  if (!root) return;

  const status = webmcpLine(Boolean((options.getModelContext ?? getModelContext)()));
  root.querySelector("[data-pb-webmcp]")?.replaceChildren(dot(status.ok), status.text);

  const missing = root.querySelector<HTMLElement>("[data-pb-webmcp-missing]");
  if (missing) missing.hidden = status.ok;
}

/**
 * Paint the USDC Balance card on the owner's profile.
 */
export function mountAgentFunding(options: MountOptions = {}) {
  const root = options.root ?? globalThis.document?.getElementById("pb-agent-funding");
  if (!root) return;

  const profileId = options.signedInProfileId ?? signedInProfileId;
  const load = options.readPaymentReadiness ?? readPaymentReadiness;
  const paymentsEnabled = root.getAttribute("data-payments-enabled") === "true";
  const signedIn = Boolean(profileId());

  const balance = root.querySelector("#pb-fund-balance");

  const refresh = () => {
    if (!paymentsEnabled || !signedIn) return;
    if (balance) balance.textContent = "Loading…";
    load({
      fetch: options.fetch,
      signedIn: true,
      paymentsEnabled: true,
    }).then(readiness => paintFunding(root, readiness));
  };

  refresh();

  const check = root.querySelector("#pb-fund-check");
  if (check) check.addEventListener("click", refresh);
  root.addEventListener("pb:card-topup", refresh);
}

function paintFunding(root: Element, readiness: FundingReadiness | null) {
  const wallet = root.querySelector("#pb-fund-wallet");
  if (wallet && readiness?.wallet_address) wallet.textContent = readiness.wallet_address;

  // A failed read says so; it never shows as zero or as the last figure.
  const balance = root.querySelector("#pb-fund-balance");
  if (balance) {
    balance.textContent = readiness?.balance_usdc ? `${readiness.balance_usdc} USDC` : "Couldn’t be read";
  }

  const request = root.querySelector<HTMLTextAreaElement>("#pb-funding-request");
  if (request) {
    request.value =
      readiness?.funding_request ??
      (readiness?.wallet_address ? fundingRequestText({walletAddress: readiness.wallet_address}) : "");
  }
}

function dot(ok: boolean): HTMLSpanElement {
  const mark = document.createElement("span");
  mark.className = ok ? "pb-setup-dot is-full" : "pb-setup-dot is-empty";
  mark.setAttribute("aria-hidden", "true");
  return mark;
}
