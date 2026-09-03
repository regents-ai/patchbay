import {loadPrivyBridge, privyAppId} from "../privy/account.js";

const INTENTS_PATH = "/api/payment_intents";
const CHALLENGE_HEADER = "payment-required";
const SIGNATURE_HEADER = "payment-signature";
const X402_VERSION = 2;
const EVM_NETWORK = /^eip155:(\d+)$/;

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
 *
 * @param {{fetch?: typeof globalThis.fetch, csrfToken?: string, document?: Document, signer?: (doc: Document) => Promise<object>}} options
 * @param {{kind: string, args: object}} action
 * @returns {Promise<{status: number, body: object | null, intent?: object, unsigned?: string}>}
 */
export async function payForIntent(options, {kind, args}) {
  const created = await request(options, INTENTS_PATH, {method: "POST", json: {kind, args}});
  if (created.status !== 201) return answer(created);

  const intent = created.body;
  const executePath = `${INTENTS_PATH}/${encodeURIComponent(intent.id)}/execute`;
  const challenged = await request(options, executePath, {method: "POST"});
  if (challenged.status !== 402) return answer(challenged, intent);

  const challenge = decodeChallenge(challenged.challenge);
  const requirement = challenge?.accepts?.[0];
  const chainId = chainIdOf(requirement);
  if (chainId === null) return answer(challenged, intent, "unsupported_challenge");

  const signer = await (options.signer ?? bridgeSigner)(options.document ?? globalThis.document);
  if (!signer.ok) return answer(challenged, intent, signer.reason);

  const typedData = transferAuthorization(requirement, chainId, signer.address);
  const signed = await signer.signTypedData(typedData);
  if (!signed.ok) return answer(challenged, intent, signed.reason);

  const payment = {
    x402Version: X402_VERSION,
    accepted: requirement,
    payload: {signature: signed.signature, authorization: typedData.message},
    extensions: challenge.extensions,
  };
  const settled = await request(options, executePath, {
    method: "POST",
    headers: {[SIGNATURE_HEADER]: encodeBase64Json(payment)},
  });

  return answer(settled, intent);
}

function answer({status, body}, intent, unsigned) {
  return {status, body, ...(intent && {intent}), ...(unsigned && {unsigned})};
}

// The wallet the page signed in with, reached through the same Privy bridge
// the account strip uses. It answers the signing address first, because the
// authorization names its signer before it is signed.
async function bridgeSigner(doc) {
  const appId = privyAppId(doc);
  if (!appId) return {ok: false, reason: "unconfigured"};

  const bridge = await loadPrivyBridge(doc);
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
function chainIdOf(requirement) {
  if (requirement?.scheme !== "exact") return null;
  const match = EVM_NETWORK.exec(requirement.network ?? "");
  return match ? Number(match[1]) : null;
}

function transferAuthorization(requirement, chainId, from) {
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

function decodeChallenge(header) {
  if (typeof header !== "string" || header === "") return null;

  try {
    const bytes = Uint8Array.from(atob(header), char => char.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

function encodeBase64Json(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(""));
}

async function request(options, url, {method, json, headers = {}}) {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") return unreachable("This page cannot reach Patchbay.");

  try {
    const response = await fetchImpl(url, {
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
    };
  } catch (error) {
    return unreachable(
      `Patchbay could not be reached: ${String(error?.message ?? error).slice(0, 200)}`,
    );
  }
}

function unreachable(problem) {
  return {status: 0, body: {error: problem, problem_code: "unreachable"}, challenge: null};
}

async function readBody(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}
