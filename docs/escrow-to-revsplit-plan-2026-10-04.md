# Escrow revenue to REGENT stakers: plan (4 Oct 2026)

Sean's 39 b: all Regents Labs USDC revenue goes to the REGENT revenue staking
contract on Base. His 41 a chose the route for every product: the payer pays
the product's operator wallet, and the server deposits it at once with
`depositUSDC`, tagged with its source. HQ decision 40 (the address) is open;
HQ reads it as RegentRevenueStaking `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.

Nothing here is deployed or released without Sean's separate go.

## Where Patchbay stands

| Revenue | Goes to today | After this plan |
| --- | --- | --- |
| Jev assist fee | operator wallet, then `depositUSDC` to 0xb027 (`patchbay.assist`) | unchanged |
| Bounty 10% on release or refund | Safe `0x9fa1…9a3e`, written into the escrow and unchangeable | operator wallet, then `depositUSDC` to 0xb027 (`patchbay.escrow`) |

## 1. Contract: same code, new deployment

The live escrow `0xFA9C…aDfE` fixed its 10% recipient at deployment, so it
cannot be pointed anywhere else. The same source is deployed again with
`TREASURY` set to the Patchbay operator wallet `0x18E8…def0` (the assist fee's
pay-to). Operator and owner stay as they are: operator `0x18E8…def0`, owner the
Safe. Only the NatSpec words for `treasury` change ("the Patchbay operator
wallet, which forwards each share to the REGENT stakers").

Limit to know: the recipient is fixed. If the operator key is ever replaced,
the shares keep arriving at the old address, so a key change means another
escrow deployment.

## 2. Payments library: forward an amount the chain paid

`RegentPayments.FeeForward.submit/2` forwards a payment intent paid into the
operator wallet. The escrow's 10% arrives from the escrow contract, not from an
intent, so the library needs a second entry that takes the amount and the
paying wallet directly and runs the same approve-then-deposit steps;
`submit/2` becomes the intent lookup in front of it. The library lives in
repos/regents (`payments`), so the Regents lane makes this change.

## 3. Patchbay: record the share, forward it with AshOban

- Each bounty gets the share it owes: the credited amount minus 90% rounded
  down, the same sum the contract pays.
- A release Patchbay makes, and a refund anyone makes that the escrow watch
  finds, both mark the share as due.
- An AshOban trigger forwards each due share with the payments library, tagged
  `patchbay.escrow` and referenced to the paying wallet, with the assist fee's
  states: taken in a write of its own, put back when nothing was sent, marked
  failed with the hash when the deposit reverted or had no answer.
- The escrow watch is a hand-built polling loop today. Its two passes move to
  AshOban scheduled triggers in the same change.

## 4. Cutover (decision 44)

- New escrow deployed by Sean's signer, then `ESCROW_CONTRACT_ADDRESS` on Fly
  points at it; new bounties go there.
- The old escrow holds one bounty (1 USDC, funded 22 Sep 19:42Z, no accepted
  answer). Anyone may refund it from 22 Oct 19:42Z: 0.90 USDC to the asker,
  0.10 USDC to the Safe. The Safe deposits that 0.10 by hand or leaves it.

## Checks before release

- Foundry: the existing escrow tests with the treasury set to the operator.
- A lab chain: credit, release and refund on a new escrow, then the share
  forwarded and seen in `depositUSDC` with the `patchbay.escrow` tag.
- A share whose deposit reverts is marked failed and never re-sent blind.
