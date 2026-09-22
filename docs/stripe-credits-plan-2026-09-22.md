# Card bundles for Patchbay Credits — plan (2026-09-22)

Status: DRAFT, nothing built. Written 2026-09-22 by the Patchbay lane
(session 14427ac1). Founder answers so far: "4. a" (design Stripe bundles
now), every card purchase gets a ledger line and shows in the profile's
payment history, card money stays in Stripe payouts, USDC fee forwarding to
staking stays as it is, and on this plan's first draft: the balance pays for
fixes and priority reports ("2. b"), agents may spend it too ("3. b"),
bundles start at $2 ("4. start at $2 for stripe"), and an existing Regents
Labs Stripe account is used ("5. b"). On the second draft: a card-paid
report's bounty stays in Patchbay Credits ("3. b") and the Stripe account is
the Regents Labs one under sean@regents.sh ("4. sean@regents.sh"). Then:
Privy's card top-up ships first ("2. a"; commit 7a6de3d), and Stripe Link must
be supported because Link's agent wallet is what Muse and Grok Bot pay with
("1. https://stripe.com/payments/link is usable by muse agents and grok
bots, so we need to support it").

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
`profile_id`, `kind` (`card_purchase | spend | card_reversal | bounty_award |
bounty_fee | bounty_return`), `report_id` (bounty lines only), `amount_atomic` (signed, 6 decimals like
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
together, then the report is published from its frozen draft as today. No
USDC moves and the escrow contract is not used: the spend line is the held
bounty. The report's bounty follows the escrow's rules on the ledger instead.
Accepting an answer writes `bounty_award` (90%) to the answer author's
profile and `bounty_fee` (10%) as Patchbay's; after 30 days without an
accepted answer the asker may take it back as `bounty_return` (90%) plus
`bounty_fee` (10%), the same split the contract uses. Each is written once
per report under a per-report lock. An author who wants USDC is paid in USDC
on reports the asker paid in USDC. This closes the stolen-card cash-out: card
money can never leave Patchbay as USDC.

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

## Stripe Link, for people and for agents

Read from Stripe's docs on 2026-09-22 (docs.stripe.com/payments/link,
link.com/agents, /agentic-commerce/link-cli, /payments/machine,
/payments/machine/mpp, /agentic-commerce/concepts/shared-payment-tokens).

**People.** Link is Stripe's saved-card wallet. Stripe Checkout includes it
with no extra work, so the bundles page above offers Link as it stands.

**Agents.** Link's agent wallet (live today for Muse, Grok Bot and Instinct;
US consumers) pays in two ways, and the person approves each purchase in the
Link app:
- a one-time virtual card, which works on any card form, the bundles page
  included, with nothing more built;
- a shared payment token (SPT) over HTTP 402, through the Machine Payments
  Protocol (MPP, mpp.dev, by Stripe and Tempo). This is the path an agent
  takes on an endpoint, with no page.

**What Patchbay adds for MPP.** The agent doors already answer 402 with x402
terms; they would also carry an MPP challenge
(`WWW-Authenticate: Payment id=…, realm=…, method="stripe", intent="charge",
request=…`, bound to the server with an HMAC secret). An agent that answers
with an SPT is charged with one Stripe call:
`POST /v1/payment_intents` with `amount`, `currency=usd`,
`payment_method_data[shared_payment_granted_token]=spt_…` and
`confirm=true`. The money lands in Stripe like any card payment, with normal
refunds and disputes, so `charge.refunded` and `charge.dispute.created` are
handled as above.
- Stripe's own library for this (`mppx`) is Node only, so Patchbay writes the
  challenge and credential checks in Elixir from the mpp.dev spec (not yet
  read in full) and proves them with `npx mppx validate` against a test
  server, then live.
- Needs: a Stripe profile (its `profile_…` id becomes
  `STRIPE_PROFILE_ID`), and the founder accepting Stripe's agentic commerce
  seller preview terms in the dashboard. Once working, Patchbay can be listed
  in the Stripe Directory (machine-payments@stripe.com, with the llms.txt
  link) so agents find it.
- Limits: $0.50 is the smallest card charge through an SPT, and SPTs work in
  the US, Canada and most of Europe.

**What that means for prices.** A fix is 0.10, below Stripe's $0.50 card
minimum, so an agent paying by Link cannot pay for one fix at its USDC
price. Priority reports (1.00 and up) and bundles ($2 and up) are above it.

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
- With Link for agents: an MPP challenge beside the x402 one on the agent
  doors, the SPT charge, and tests against Stripe's test tokens
  (`/v1/test_helpers/shared_payment/granted_tokens`).
- Size: about four to five days for bundles, plus two to three for Link
  payments by agents, with review, since this is money code.

## Founder decisions (all taken, 2026-09-22)

1. **An agent paying by Link for fixes: b.** The agent buys a bundle by Link
   ($2 and up) for a wallet it names, and fixes come off that wallet's
   balance with the wallet's signature. Agents get wallets through Bankr's
   skills.
2. **Priority reports paid by Link: b, now,** for agents that name a wallet.
   The wallet is the asker and later signs to accept an answer or take the
   bounty back.
3. **Go-ahead: yes.** Bundles and Link are built together.
4. **Stripe setup: done by the founder.** Regents Labs account under
   sean@regents.sh; webhook to `https://patchbay.help/webhooks/stripe` on API
   version `2026-08-26.dahlia` for `checkout.session.completed`,
   `charge.refunded` and `charge.dispute.created` only (a Link charge by an
   agent is answered in the same request, so it needs no event);
   `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and `STRIPE_PROFILE_ID` are on
   `patchbay-regents`. Privy card funding is switched on.

5. **Whose balance (Q1): b, as pairing.** A person buys credits for their
   agent. The agent pairs with the person using a one-time code from the
   person's profile page, good for ten minutes, which the agent sends signed
   by its wallet: the SIWA-signed agent API (`POST /api/agent/pairing`), the
   hosted MCP tool `pair_with_person` (EIP-712 signature) or the command line
   (`patchbay agent pair`). The person and every agent paired with them share
   one balance, held on the person's profile. An agent that already holds
   credits moves them into it when it pairs. The person can unpair from their
   page, which stops that agent spending at once. An agent pairs with one
   person at a time; a new code moves it to the new person.
6. **People keep spending too.** The fix form and the page's priority-report
   tool still pay from the signed-in person's balance.
7. **The spend signature (Q2): a.** Agents spend only through Patchbay's own
   agent connection: the SIWA-signed agent API, whose signed request is the
   wallet's word for that exact purchase, and hosted MCP with a
   `SpendCredits` EIP-712 signature.
8. **Link for a wallet that proves nothing (Q3): a.** Anyone may add credits
   to any wallet; nobody can take them out. Credits bought for a paired
   agent's wallet land on its person's balance.
9. **A Link charge whose write fails (Q4): a.** An idempotency key per
   payment (sha256 of the shared payment token), and leftovers matched by
   hand.
10. **Credits passed through a bounty before a chargeback: accepted.** The
    loss is at most one bundle and credits never become money.
11. **A won dispute gives the credits back: yes.** The founder adds
    `charge.dispute.closed` to the webhook; a dispute closed as won writes the
    taken-back amount back once.

## How pairing and the shared balance work

- `agent_profiles.paired_person_id` points a wallet agent at the Privy person
  it is paired with. A balance's holder is the person for a paired agent and
  the profile itself otherwise; every credits line is written on the holder.
  A spend by a paired agent is written on the person, naming the agent's own
  payment intent, so the person's history shows every agent's spends.
- `pairing_codes`: one live code per person, stored as a sha256 hash with its
  expiry. Issuing a new one replaces the old; pairing uses it up.
- Pairing, under both profiles' credits locks taken in a fixed order, moves
  the agent's own balance, whatever its sign, onto the person with a
  `pairing_move` line on each side.
- Refunds and disputes are written on the current holder of the profile the
  purchase was credited to. Bounty payouts go to the holder of the author or
  the asker.

## Build order

1. Ledger and payment history (owner only, page only).
2. Card bundles: bundles page, Stripe Checkout, the webhook.
3. Fixes paid from the balance on the page (runs marked `:card`, nothing
   forwarded to staking).
4. Priority reports paid from the balance, bounty held on the ledger (award
   90/10 on accept, return 90/10 after 30 days, each once).
5. Pairing and the shared balance (P).
6. Agents spend their balance: SIWA-signed agent API and hosted MCP with
   `SpendCredits`; the balance read for agents (S5).
7. Link: an agent buys a bundle for a named wallet (S6).
8. Link: an agent pays a priority report for a named wallet (S7).
9. A won dispute gives the credits back.
