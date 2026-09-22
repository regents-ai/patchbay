import {loadPrivyBridge, privyAppId} from "./privy/account.js"

const WORDS = {
  opening: "Opening the card top-up.",
  confirmed: "USDC is on its way to your wallet on Base. It can take a few minutes to arrive.",
  submitted: "Your card purchase was sent. The USDC reaches your wallet on Base once the card provider finishes, usually within minutes.",
  unconfigured: "Paying by card is not set up on this Patchbay.",
  unloadable: "The card window could not be loaded. Check your connection and try again.",
  unready: "The card window did not answer in time. Try again.",
  no_wallet: "Sign in with a wallet first, at the top of the page.",
  unfinished: "The card top-up did not finish. Your card was only charged if the card provider told you so.",
}

/**
 * What to tell the person after a card top-up, from the bridge's answer.
 *
 * @param {{ok: true, status: string} | {ok: false, reason: string}} outcome
 * @returns {string}
 */
export function topUpWords(outcome) {
  if (outcome.ok) return WORDS[outcome.status] ?? WORDS.submitted
  return WORDS[outcome.reason] ?? WORDS.unfinished
}

/**
 * Buys USDC by card into the wallet this page is signed in with, through
 * Privy's card top-up.
 *
 * @param {Document} doc
 * @param {{loadBridge?: typeof loadPrivyBridge}} [options]
 * @returns {Promise<{ok: true, status: string} | {ok: false, reason: string}>}
 */
export async function topUpByCard(doc, options = {}) {
  const appId = privyAppId(doc)
  if (!appId) return {ok: false, reason: "unconfigured"}

  const bridge = await (options.loadBridge ?? loadPrivyBridge)(doc)
  if (!bridge) return {ok: false, reason: "unloadable"}

  return bridge.addFundsByCard(appId)
}

/**
 * Every "Add USDC with a card" button on the page. Each press opens the card
 * top-up and writes what happened into the status line the button names;
 * once a purchase went through, the button announces `pb:card-topup` so the
 * balance beside it can be read again.
 *
 * @param {{document?: Document, loadBridge?: typeof loadPrivyBridge}} [options]
 */
export function mountCardTopUp(options = {}) {
  const doc = options.document ?? globalThis.document
  for (const button of doc?.querySelectorAll?.("[data-pb-card-topup]") ?? []) {
    button.addEventListener("click", async () => {
      const status = doc.getElementById(button.dataset.pbCardTopup)
      const say = words => { if (status) status.textContent = words }

      say(WORDS.opening)
      const outcome = await topUpByCard(doc, options)
      say(topUpWords(outcome))
      if (outcome.ok) button.dispatchEvent(new CustomEvent("pb:card-topup", {bubbles: true, detail: outcome}))
    })
  }
}
