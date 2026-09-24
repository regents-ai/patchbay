# Buying credits in Stripe test mode — runbook (2026-09-24)

For the founder. Runs the credit purchase, refund and dispute journeys
against real Stripe test mode on a local Patchbay. Nothing here touches
live money or the production site. The agent never reads the keys; you
put them in `platform/.env` yourself.

## Once: keys and the event relay

1. In the Stripe dashboard (Regents Labs account), switch to **Test mode**.
   Under Developers → API keys, create a restricted key that can write
   Checkout Sessions. It starts `rk_test_`.
2. Install the Stripe command line tool and sign in:

   ```bash
   brew install stripe/stripe-cli/stripe
   ```

   ```bash
   stripe login
   ```

3. Start the relay that forwards Stripe's test events to your local
   Patchbay. It prints a signing secret starting `whsec_`; leave it running.

   ```bash
   stripe listen --forward-to localhost:4000/webhooks/stripe --events checkout.session.completed,checkout.session.expired,charge.refunded,charge.dispute.created,charge.dispute.closed
   ```

4. In `platform/.env`, set `STRIPE_SECRET_KEY` to the `rk_test_` key and
   `STRIPE_WEBHOOK_SECRET` to the `whsec_` secret, then start Patchbay
   locally as usual (it listens on port 4000).

## 1. Credits arrive only after the payment

Open a payment page for a wallet (any Base address; use one you control so
you can sign in as it later):

```bash
curl -s -X POST localhost:4000/api/credits/checkout -H 'content-type: application/json' -d '{"wallet_address":"0xYOUR_WALLET","bundle_dollars":10}'
```

- The answer names the wallet, the credits (10.00) and `checkout_url`.
- Open `checkout_url`. The page says "10 Patchbay Credits for wallet
  0x…" with the full wallet in the description.
- Before paying, the wallet's balance is unchanged.
- Pay with the test card `4242 4242 4242 4242`, any future date, any CVC.
  To try Link, pick Link on the page and use Stripe's test Link sign-in.
- You land back on the wallet's Patchbay page with "Thank you. The credits
  you paid for are added to the Patchbay Credits of wallet 0x…".
- The relay window shows `checkout.session.completed` answered `200`.
  Signed in as that wallet (or its paired person), the profile shows 10.00
  more credits and a "Credits bought by card" line.

## 2. A repeated event does not add twice

Copy the `evt_` id of that `checkout.session.completed` from the relay
window and send it again:

```bash
stripe events resend evt_PASTE_ID
```

The relay shows `200` again; the balance is unchanged.

## 3. An abandoned page adds nothing

Open another payment page with the same curl, then either press the back
arrow on the Stripe page (you land on "Nothing was charged, and nothing was
added to this wallet's credits.") or expire it:

```bash
stripe checkout sessions expire cs_test_PASTE_ID
```

The relay shows `checkout.session.expired` answered `200`; the balance is
unchanged.

## 4. Credits for a paired agent land on its person

Pair the wallet with a person (Pair an agent on the person's profile page,
then `patchbay agent pair` from the wallet), and buy again for the wallet.
The curl answer's `recipient.shares_with` names the person, the Stripe page
says the wallet shares its credits with the person it is paired with, and
the credits appear on the person's balance.

## 5. Refund, dispute and a won dispute

- **Refund:** `stripe refunds create --payment-intent pi_PASTE_ID`. The
  credits are taken back, shown as "Card payment refunded or disputed".
- **Dispute:** pay a new page with the test card `4000 0000 0000 0259`.
  Stripe opens a dispute on its own; the credits are taken back at once.
- **Won dispute:** in the dashboard, open that dispute and submit evidence
  with the text `winning_evidence`. Stripe closes it as won within a few
  minutes; the amount taken is given back once, shown as "Card dispute
  closed, credits given back". Resending that `charge.dispute.closed`
  event gives nothing more.

## Before production

The production webhook at `https://patchbay.help/webhooks/stripe` must also
send `charge.dispute.closed` (founder decision 11 in
`stripe-credits-plan-2026-09-22.md`); without it a won dispute is never
given back. `checkout.session.expired` needs no subscription: it adds
nothing either way.
