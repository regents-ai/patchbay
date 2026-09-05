import assert from "node:assert/strict";
import test from "node:test";

import {
  USDC_CONTRACT,
  fundingHandoffText,
  mapBalanceHttp,
  mapUnsignedReason,
  needsSignIn,
  notConfigured,
  paidToolShortfall,
  pageSignedIn,
  readPaymentReadiness,
  withRequiredAmount,
} from "../../js/webmcp/payment_readiness.js";

const WALLET = `0x${"1".repeat(40)}`;

function httpOk(body) {
  return {ok: true, status: 200, body};
}

test("unsigned pages map to needs_human_sign_in without calling HTTP", async () => {
  const fetch = () => {
    throw new Error("unsigned must not hit the balance door");
  };

  const readiness = await readPaymentReadiness({fetch, signedIn: false, paymentsEnabled: true});

  assert.deepEqual(readiness, needsSignIn());
  assert.equal(readiness.status, "needs_human_sign_in");
  assert.equal(readiness.balance_usdc, null);
  assert.match(readiness.human_action, /Sign in on the current Patchbay page/);
});

test("a zero balance maps to needs_human_funding with the handoff text", () => {
  const readiness = mapBalanceHttp(
    httpOk({
      available_usdc: "0.00",
      verified_payout_address: WALLET,
      network: "eip155:8453",
      asset: "USDC",
      profile_id: "agt_1",
    }),
  );

  assert.equal(readiness.status, "needs_human_funding");
  assert.equal(readiness.balance_usdc, "0.00");
  assert.equal(readiness.wallet_address, WALLET);
  assert.equal(readiness.network, "eip155:8453");
  assert.equal(readiness.asset, "USDC");
  assert.equal(
    readiness.human_handoff,
    fundingHandoffText({walletAddress: WALLET}),
  );
  assert.match(readiness.funding_request, /native USDC/);
  assert.match(readiness.funding_request, new RegExp(USDC_CONTRACT));
  assert.match(readiness.funding_request, /Do not send me a private key or recovery phrase/);
  assert.equal("found" in readiness, false);
});

test("a positive balance maps to ready", () => {
  const readiness = mapBalanceHttp(
    httpOk({
      available_usdc: "8.40",
      verified_payout_address: WALLET,
      network: "eip155:8453",
      profile_id: "agt_1",
    }),
  );

  assert.equal(readiness.status, "ready");
  assert.equal(readiness.balance_usdc, "8.40");
  assert.equal(readiness.network, "eip155:8453");
  assert.equal(readiness.can_use_paid_patchbay_tools, true);
  assert.equal(readiness.available_usdc, "8.40");
  assert.equal("found" in readiness, false);
});

test("BalanceController not_configured and a disabled rail map to not_configured", async () => {
  const fromHttp = mapBalanceHttp({
    ok: false,
    status: 503,
    body: {error: "Reading balances is not set up on this Patchbay.", problem_code: "not_configured"},
  });
  assert.equal(fromHttp.status, "not_configured");
  assert.match(fromHttp.message, /not set up/);

  const fromRail = await readPaymentReadiness({
    signedIn: true,
    paymentsEnabled: false,
    fetch: () => {
      throw new Error("disabled payments must not hit the balance door");
    },
  });
  assert.deepEqual(fromRail, notConfigured());
});

test("a paid-tool shortfall uses the funding handoff shape", () => {
  const ready = mapBalanceHttp(
    httpOk({available_usdc: "1.00", verified_payout_address: WALLET, network: "eip155:8453"}),
  );
  const short = withRequiredAmount(ready, "5.00");

  assert.deepEqual(short, paidToolShortfall({
    walletAddress: WALLET,
    balanceUsdc: "1.00",
    requiredUsdc: "5.00",
  }));
  assert.equal(short.status, "needs_human_funding");
  assert.equal(short.required_usdc, "5.00");
  assert.equal(short.network.caip2, "eip155:8453");
  assert.equal(short.asset.contract, USDC_CONTRACT);
  assert.equal(
    short.human_handoff,
    `Please send 5.00 native USDC on Base mainnet to ${WALLET}. Do not send it on Ethereum or another network. Do not send me a private key or recovery phrase.`,
  );
  assert.equal(short.next_action, "After funding, call get_my_usdc_balance and retry this action.");
});

test("pageSignedIn reads the pb-profile meta and never invents a session", () => {
  assert.equal(pageSignedIn({signedIn: false}), false);
  assert.equal(pageSignedIn({profileId: "agt_1"}), true);
  assert.equal(
    pageSignedIn({
      signedInProfileId: () => null,
    }),
    false,
  );
});

test("unsigned wallet reasons from payForIntent use the same status words", () => {
  assert.equal(mapUnsignedReason("signed_out").status, "needs_human_sign_in");
  assert.equal(mapUnsignedReason("no_wallet").status, "needs_human_sign_in");
  assert.equal(mapUnsignedReason("unconfigured").status, "not_configured");
  assert.equal(mapUnsignedReason("refused"), null);
});
