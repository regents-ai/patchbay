# Escrow revenue to REGENT stakers (4 Oct 2026)

Sean's 39 b: all Regents Labs USDC revenue goes to the REGENT revenue staking
contract on Base. His 43 a: the new escrow keeps the 10% and anyone can push it
into the staking contract with `depositUSDC`, so payouts and refunds never
depend on staking being unpaused. HQ decision 40 (the address) is open; HQ
reads it as RegentRevenueStaking `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.

Nothing here is deployed or released without Sean's separate go and signer.

## Where Patchbay stands

| Revenue | Goes to today | After the new escrow |
| --- | --- | --- |
| Jev assist fee | operator wallet, then `depositUSDC` to 0xb027 (`patchbay.assist`) | unchanged |
| Bounty 10% on release or refund | Safe `0x9fa1…9a3e`, fixed in the live escrow | kept in the escrow, then `pushRevenue` deposits it to 0xb027 (`patchbay.escrow`) |

## The contract (built, on branch escrow-revsplit)

`contracts/src/PatchbayEscrow.sol`:

- The constructor takes the staking contract in place of the treasury; it is
  fixed at deployment.
- `release` and `refund` pay the 90% as before and add the 10% to
  `revenueOwed`. Neither touches the staking contract, so a paused staking
  contract never holds up a winner or an asker.
- `pushRevenue()`, open to anyone, deposits all of `revenueOwed` with
  `depositUSDC(amount, "patchbay.escrow", 0)`. While staking is paused it
  reverts and the revenue stays owed.
- `credit` can never attribute the revenue owed to a bounty.

Checks run: `forge test` (14, including a paused staking contract and the
revenue owed being out of reach of `credit`), `forge fmt --check`, slither (one
note, the refund delay's use of block time, as before), and `script/Sanity.s.sol`
on a local copy of Base, which released one bounty, refunded another and pushed
the 20 USDC kept into the real staking contract at 0xb027.

The server's copy of the interface (`contracts/abi/PatchbayEscrow.json`) is
regenerated; credit, release and refund calls are unchanged, and the server
suite runs clean.

## Open

- Who presses `pushRevenue` (decision 45): Patchbay after each payout or
  refund, through a background job on the operator wallet, or a person by hand.
- Cutover (decision 44): the new escrow is deployed by Sean's signer with
  `STAKING`, `OPERATOR` and `OWNER` set, then `ESCROW_CONTRACT_ADDRESS` on Fly
  points at it. The old escrow holds one bounty (1 USDC, funded 22 Sep
  19:42Z); anyone may refund it from 22 Oct 19:42Z, sending 0.90 USDC to the
  asker and 0.10 USDC to the Safe.
