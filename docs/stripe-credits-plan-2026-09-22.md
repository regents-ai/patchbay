# Card bundles for Patchbay Credits — plan (2026-09-22)

Status: DRAFT, nothing built. Written 2026-09-22 by the Patchbay lane
(session 14427ac1). Founder answers so far: "4. a" (design Stripe bundles
now), every card purchase gets a ledger line and shows in the profile's
payment history, card money stays in Stripe payouts, USDC fee forwarding to
staking stays as it is, and on this plan's first draft: the balance pays for
fixes and priority reports ("2. b"), agents may spend it too ("3. b"),
bundles start at $2 ("4. start at $2 for stripe"), and an existing Regents
Labs Stripe account is used ("5. b"). Two decisions remain, at the end.

## What is there today

Patchbay Credits is a pay-per-action rail, not a balance. Every paid action
is its own USDC payment on Base at the moment of use: a payment intent
(`Patchbay.Payments.PaymentIntent`) is prepared, the wallet signs the exact
terms, the facilitator settles them, and a `PaymentReceipt` with the
transaction hash is written. There is no stored balance, no ledger and no
per-person payment history; a profile only shows tip totals.

| Action | Price | Money goes to |
|---|---|---|
| Fix (`jev_assist`) | 0.10 USDC | operator wallet, then forwarded to the REGENT staking contract |
| Priority report (`special_post`) | 1.00–100.00 USDC | the escrow contract; 90% to the accepted answer's author, 10% to the treasury, or back to the asker after 30 days |
| Tip (`agent_tip`) | 0.10–20.00 USDC | the recipient's own wallet |

Card bundles are a new thing: a prepaid balance that Patchbay holds, bought
by card and spent on fixes and priority reports.

## What a person gets

1. Signed in, a person opens **Buy Patchbay Credits** and picks a bundle.
2. Stripe's own checkout page takes the card. Patchbay never sees card
   details.
3. Back on Patchbay, the balance shows the bundle added, and the payment
   history has a line: date, "Card purchase", amount, balance after.
4. Paying for a fix or a priority report, the form offers **Pay from your
   balance** when the balance covers it, next to the existing wallet
   payment. Paying from the balance adds a history line and the fix or report
   goes ahead at once, with no wallet prompt.
5. Their agent can do the same through the agent doors, by having the
   person's wallet sign for that one purchase (below).

One credit is one US dollar and pays what one USDC pays, so every price on
the site stays as it is. Tips stay USDC only.

## Bundles and what Stripe keeps

Stripe's standard US card price is 2.9% plus $0.30 a payment.

| Bundle | Stripe keeps | Patchbay receives | Fixes it buys |
|---|---|---|---|
| $2 | ~$0.36 (18%) | ~$1.64 | 20 |
| $5 | ~$0.45 (9%) | ~$4.55 | 50 |
| $10 | ~$0.59 (6%) | ~$9.41 | 100 |
| $20 | ~$0.88 (4%) | ~$19.12 | 200 |
| $50 | ~$1.75 (3.5%) | ~$48.25 | 500 |

The sizes are a fixed list on the server. The page never sends an amount.

## How it works

**Ledger (new Ash resource `Patchbay.Payments.CreditLine`, table
`credit_lines`).** One row per change to a balance, never edited:
`profile_id`, `kind` (`card_purchase | spend | card_reversal`, plus the
bounty kinds if decision 1 is b), `amount_atomic` (signed, 6 decimals like
USDC), `stripe_checkout_session_id` (unique, card purchases only),
`payment_intent_id` (unique, spends only), `inserted_at`. The balance is the
sum of a profile's lines, read from the rows. Nothing is cached in memory.

**Buying.** `POST /credits/checkout` with a bundle id, signed in only. The
server makes a Stripe Checkout Session (card only, the bundle's fixed price,
`client_reference_id` = profile id, metadata = bundle id) with Req and
redirects to Stripe's page. Nothing is written yet. Two presses make two
checkout pages; each is paid only if the person finishes it.

**Recording.** `POST /webhooks/stripe` checks Stripe's signature
(`STRIPE_WEBHOOK_SECRET`, HMAC-SHA256 over the raw body, five-minute window)
and handles `checkout.session.completed` with `payment_status: "paid"`. It
writes one `card_purchase` line keyed on the session id, so Stripe's retries
are no-ops. The return page reads the balance only; it never writes.

**Spending on a fix.** The existing `jev_assist` intent runs through
`Purchase` with a new way to settle, `settle_with: :credits`. Under a
per-profile advisory lock it sums the balance, refuses when it is short, and
otherwise writes the `spend` line and marks the intent settled and applied in
one transaction. The fix then opens exactly as a paid one does. The run's
`deposit_status` is a new `:card`, so the operator never forwards anything to
staking for it; its money is in Stripe.

**Spending on a priority report.** Same `settle_with: :credits` on the
`special_post` intent: the spend line and the settled intent commit
together, then the report is published from its frozen draft as today. What
happens to the bounty depends on decision 1.

**Agents spending the balance.** An agent door (`post_priority_report`,
`request_assist`, `POST /api/agent/payment_intents`) takes
`pay_with: "credits"`. The server answers with EIP-712 typed data for one
`SpendCredits` action (the intent id, the amount, the wallet, a challenge
this server signed, good for ten minutes), the same pattern
`PatchbayWeb.MCP.WalletProof` already uses for accepting and withdrawing.
The wallet signs it, the agent calls again with the signature, and the
server spends the balance of the profile whose wallet recovered from the
signature. So an agent spends a person's balance only with that person's
wallet signing for that exact purchase. A profile signed in through Privy
has its wallet address on the profile already.

**Refunds and disputes.** `charge.refunded` and `charge.dispute.created`
write a `card_reversal` line for the refunded amount, keyed on the Stripe
event. The balance can go below zero. A negative balance only stops spending
from the balance; wallet payments are untouched.

**Payment history.** A **Payment history** section on the person's own
profile page, shown only to them: card purchases, spends and reversals from
the ledger, and USDC payments from their receipts (action, amount,
transaction link), newest first, with the balance.

**Settings.** `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` as Fly secrets
on `patchbay-regents`, recorded by name and fingerprint only. Card bundles
stay hidden until both are set.

**Words on the page.** "Patchbay Credits" throughout, "balance" for what a
person holds, and never "Rewards". The buy page says plainly that credits pay
for Patchbay fixes and priority reports, are not refundable as cash, cannot
be sent to anyone else, and do not expire.

## What changes in the code (estimate)

- New: `CreditLine` resource + migration, `Patchbay.Payments.Credits`
  (balance, spend under the lock), `Patchbay.Stripe` (two Req calls and the
  signature check), `CreditsController` (bundles page, checkout, return),
  `StripeWebhookController`, the `SpendCredits` wallet proof, and a payment
  history component on the profile.
- Changed: `Purchase` (the `:credits` settle path for `jev_assist` and
  `special_post`), `DepositStatus` (`:card`), the fix and report forms and
  their scripts (the balance button), the three agent doors, the payments
  moduledocs (Patchbay now holds prepaid credits), the privacy page, the
  CHANGELOG, `.env.example`, DEPLOY.md, HANDOFF.md, the OpenAPI files and the
  agent guides.
- Tests: webhook signature and retry, balance under parallel spends, spend
  refused when short, reversal to a negative balance, history visible only to
  its owner, a fix paid from the balance opens and is marked `:card`, a
  report paid from the balance publishes, an agent's spend with the right
  and the wrong wallet's signature.
- Size: about four to five days of work with review, since this is money
  code and now covers reports and agents.

## Founder decisions

1. **Where the bounty of a report paid from a card balance goes.** A card
   balance paying a priority report opens a way to turn a card into USDC:
   buy credits with a stolen card, post a report, answer it from a second
   account, accept, and the USDC is out long before the chargeback lands.
   a) As for USDC reports: Patchbay's operator wallet sends the USDC to the
   escrow and records it, and the accepted author is paid in USDC. Needs a
   USDC float in the operator wallet that you top up by hand, since card
   money arrives in Stripe, and is open to the stolen-card cash-out above.
   b) The bounty stays in Patchbay Credits: it is held on the ledger, the
   accepted author gets 90% as balance and the treasury 10%, and the asker
   gets it back as balance after 30 days, the same rules as the escrow. No
   USDC moves, nothing can be cashed out, and no float is needed.
   c) Reports paid from a card balance, with bounties capped at $5 each and
   $20 per person a week, paid in USDC as in a.
   Recommendation: b. It keeps your answer (the balance pays for reports)
   and removes the cash-out path. An answer's author who wants USDC can still
   be paid in USDC on reports the asker paid in USDC.
2. **The Stripe account.** Which Regents Labs Stripe account should
   Patchbay use (its name, or the email it is under)? Once the webhook
   address exists, you create the secret key and webhook in Stripe's
   dashboard and add `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` to
   `patchbay-regents` yourself.
   Recommendation: a restricted key limited to Checkout Sessions and charges,
   made for Patchbay alone, so it can be turned off without touching the
   other Regents sites.
