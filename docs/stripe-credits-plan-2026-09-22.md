# Card bundles for Patchbay Credits — plan (2026-09-22)

Status: DRAFT for founder decisions. Nothing built. Written 2026-09-22 by the
Patchbay lane (session 14427ac1) from the founder's answers: "4. a" (design
Stripe bundles now), bundles from $0.50 to $50, every card purchase gets a
ledger line and shows in the profile's payment history, card money stays in
Stripe payouts, and USDC fee forwarding to staking stays as it is.

## What is there today

Patchbay Credits is a pay-per-action rail, not a balance. Every paid action
is its own USDC payment on Base at the moment of use: a payment intent
(`Patchbay.Payments.PaymentIntent`) is prepared, the wallet signs the exact
terms, the facilitator settles them, and a `PaymentReceipt` with the
transaction hash is written. The moduledocs say "Patchbay never holds
anyone's money", and that is true today. There is no stored balance, no
ledger and no per-person payment history; a profile only shows tip totals.

| Action | Price | Money goes to |
|---|---|---|
| Fix (`jev_assist`) | 0.10 USDC | operator wallet, then forwarded to the REGENT staking contract |
| Priority report (`special_post`) | 1.00–100.00 USDC | the escrow contract |
| Tip (`agent_tip`) | 0.10–20.00 USDC | the recipient's own wallet |

So card bundles are a new thing: a prepaid balance that Patchbay holds,
bought by card and spent on Patchbay's own services.

## What a person gets

1. Signed in, a person opens **Buy Patchbay Credits** and picks a bundle.
2. Stripe's own checkout page takes the card. Patchbay never sees card
   details.
3. Back on Patchbay, the balance shows the bundle added, and the payment
   history has a line: date, "Card purchase", amount, balance after.
4. Paying for a fix, the form offers **Pay 0.10 from your balance** when the
   balance covers it, next to the existing wallet payment. Paying from the
   balance adds a history line ("Fix", −0.10, balance after) and the fix opens
   at once. No wallet prompt is needed.

One credit is one US dollar and pays what one USDC pays, so every price on
the site stays as it is.

## Bundles and what Stripe keeps

Stripe's standard US card price is 2.9% plus $0.30 a payment, and $0.50 is
Stripe's smallest charge.

| Bundle | Stripe keeps | Patchbay receives | Fixes it buys |
|---|---|---|---|
| $0.50 | ~$0.31 (62%) | ~$0.19 | 5 |
| $1 | ~$0.33 (33%) | ~$0.67 | 10 |
| $5 | ~$0.45 (9%) | ~$4.55 | 50 |
| $10 | ~$0.59 (6%) | ~$9.41 | 100 |
| $20 | ~$0.88 (4%) | ~$19.12 | 200 |
| $50 | ~$1.75 (3.5%) | ~$48.25 | 500 |

The sizes are a fixed list on the server. The page never sends an amount.

## How it works

**Ledger (new Ash resource `Patchbay.Payments.CreditLine`, table
`credit_lines`).** One row per change to a balance, never edited:
`profile_id`, `kind` (`card_purchase | spend | card_reversal`),
`amount_atomic` (signed, 6 decimals like USDC), `stripe_checkout_session_id`
(unique, card purchases only), `payment_intent_id` (unique, spends only),
`inserted_at`. The balance is the sum of a profile's lines, read from the
rows, so a restart forgets nothing. Nothing is cached in memory.

**Buying.** `POST /credits/checkout` with a bundle id, signed in only. The
server makes a Stripe Checkout Session (card only, the bundle's fixed price,
`client_reference_id` = profile id, metadata = bundle id) with Req, which the
app already uses, and redirects to Stripe's page. Nothing is written yet. Two
presses make two checkout pages; each is paid only if the person finishes it.

**Recording.** `POST /webhooks/stripe` checks Stripe's signature
(`STRIPE_WEBHOOK_SECRET`, HMAC-SHA256 over the raw body, with a five-minute
window) and handles `checkout.session.completed` with
`payment_status: "paid"`. It writes one `card_purchase` line keyed on the
session id. Stripe retries webhooks, and the unique key makes a retry a
no-op. The return page reads the balance only; it never writes.

**Spending.** Paying a fix from the balance runs the existing
`jev_assist` intent through `Purchase` with a new way to settle:
`settle_with: :credits`. Under a per-profile advisory lock it sums the
balance, refuses when it is short, and otherwise writes the `spend` line and
marks the intent settled and applied in one transaction. The fix then opens
exactly as a paid one does. There is no receipt row or transaction hash; the
spend line is the record.

**Fee forwarding.** A fix paid from the balance forwards nothing to staking,
because its money is in Stripe. The run's `deposit_status` gets a new value,
`:card`, so the operator never tries to forward it. USDC-paid fixes keep
forwarding exactly as today.

**Refunds and disputes.** `charge.refunded` and `charge.dispute.created`
write a `card_reversal` line for the refunded amount, keyed on the Stripe
event. The balance can go below zero. A negative balance only stops spending
from the balance; wallet payments are untouched.

**Payment history.** This is new: a **Payment history** section on the
person's own profile page, shown only to them. It lists card purchases,
spends and reversals from the ledger, and USDC payments from their receipts
(action, amount, transaction link), newest first, with the balance.

**Settings.** `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` as Fly secrets,
recorded by name and fingerprint only. Card bundles stay hidden until both
are set.

**Words on the page.** "Patchbay Credits" throughout, "balance" for what a
person holds, and never "Rewards". The buy page says plainly that credits pay
for Patchbay's own services, are not refundable as cash, cannot be sent to
anyone else, and do not expire.

## What changes in the code (estimate)

- New: `CreditLine` resource + migration, `Patchbay.Payments.Credits`
  (balance, spend under the lock), `Patchbay.Stripe` (two Req calls and the
  signature check), `CreditsController` (bundles page, checkout, return),
  `StripeWebhookController`, and a payment history component on the profile.
- Changed: `Purchase` (the `:credits` settle path for `jev_assist`),
  `DepositStatus` (`:card`), the fix form and `fix_form.js` (the balance
  button), the payments moduledocs (Patchbay now holds prepaid credits),
  the privacy page, the CHANGELOG, `.env.example`, DEPLOY.md and HANDOFF.md.
- Tests: webhook signature and retry, balance under parallel spends, spend
  refused when short, reversal to a negative balance, history visible only to
  its owner, fix paid from the balance opens and is marked `:card`.
- Size: about two to three days of work with review, since this is money
  code.

## Founder decisions

1. **What the balance can pay for.**
   a) Fixes only, for now.
   b) Fixes and priority reports. Patchbay would pay the escrow contract in
   USDC from the operator wallet for each report.
   c) Everything, tips included. Patchbay would send its own USDC to other
   people's wallets.
   Recommendation: a. Reports and tips move USDC to the escrow contract or to
   other people, so a card balance paying for them turns Patchbay into the
   one sending money on the buyer's behalf.
2. **Agents spending the balance.**
   a) The page only for now; agent doors stay USDC.
   b) Agents too, through the signed-in person's agent.
   Recommendation: a. Agent doors act for a wallet, and card credits belong
   to a signed-in person. Joining the two needs its own design.
3. **The $0.50 and $1 bundles.** Stripe keeps about 62% of $0.50 and 33% of
   $1.
   a) Keep all six sizes, as decided.
   b) Start at $5.
   Recommendation: a. It is your decision already, and the loss is about
   30 cents a purchase. The table above shows the cost.
4. **The Stripe account.** Is there a Stripe account for Regents Labs to use,
   and will you add `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` to
   `patchbay-regents` yourself once the webhook address exists?
   Recommendation: yes. I prepare everything, and you create the keys and
   the webhook in Stripe's dashboard.
