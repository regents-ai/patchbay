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
- The escrow's own address can never be a payer or a winner (Sean's HQ 47 a),
  so a payout can never leave money behind owned by no post.

Checks run: `forge test` (15, including the escrow refusing to pay itself, a paused staking contract and the
revenue owed being out of reach of `credit`), `forge fmt --check`, slither (one
note, the refund delay's use of block time, as before), and `script/Sanity.s.sol`
on a local copy of Base, which released one bounty, refunded another and pushed
the 20 USDC kept into the real staking contract at 0xb027.

The server's copy of the interface (`contracts/abi/PatchbayEscrow.json`) is
regenerated; credit, release and refund calls are unchanged, and the server
suite runs clean.

## Pushing (Sean's 46 a, built)

Patchbay pushes after each bounty pays out or goes back to its asker: an
AshOban trigger on the report (`:push_escrow_revenue`, fee queue, one send at
a time from the operator wallet). It waits for the payout to land, reads
`revenueOwed`, tries the push against the chain and only sends it when it
would go through, then marks the report (`escrow_revenue_pushed_at`). A push
carries every bounty's share, so a later job finds nothing kept and only
marks its report. A refused try (staking paused) costs no gas; Oban retries
with backoff, and after the fifth try the next minute's sweep queues it again,
so the stakers' money is never given up on.

Checked on a private Base fork with the real staking contract: a payout while
staking was paused sent nothing and stayed waiting; after unpausing, the retry
pushed 0.10 USDC and marked it; a refund someone else made was pushed in one
send; a run with nothing waiting sent nothing. `mix precommit`: 611 tests, 0
failures.

## Cutover (Sean's 44 a), after his deploy go and signer

1. Sean's signer deploys with `STAKING=0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`,
   `OPERATOR=0x18E8…def0`, `OWNER=0x9fa1…9a3e` (the Safe).
2. `ESCROW_CONTRACT_ADDRESS` is staged to the new address and this branch is
   released in the same deploy: the push job reads `revenueOwed`, which the old
   escrow does not have. Reports already released or refunded on the old escrow
   find nothing kept on the new one and are only marked.
3. The old escrow's one bounty (1 USDC, funded 22 Sep 19:42Z) is no longer
   visible to Patchbay. Anyone may refund it on the old contract from 22 Oct
   19:42Z (0.90 USDC to the asker, 0.10 USDC to the Safe); the report's record
   is then written by a person.
