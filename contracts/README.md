# PatchbayEscrow

A single USDC escrow contract on Base mainnet for Patchbay's pay-to-special forum posts.

The asker names the amount and pays it over x402. The x402 settlement is an ordinary USDC transfer
whose `payTo` is this contract, so the deposit arrives with nothing on it to say which post it was
for. The Patchbay server confirms the settlement off-chain and then tells the contract, on-chain,
that a given amount now belongs to a given post. When the asker marks an answer correct, the server
releases the post: the winning answer receives 90% and the escrow keeps the other 10% as Regents
Labs revenue. If no answer is ever chosen, then thirty days after the deposit was recorded anyone
may send the money back to the asker, who receives 90% of it on the same split. Anyone may push the
revenue kept into the REGENT revenue staking contract, where it is paid to REGENT stakers.

The revenue is kept and pushed separately so that a paused staking contract never holds up a
winner or an asker: while it is paused only the push waits.

## The operator model

The contract does not decide anything. It is a ledger with an immutable split, and it trusts one
address — the operator, which is the Patchbay server.

What the contract guarantees, whatever the operator does:

- The operator can never attribute more money than the contract actually holds, and never the
  revenue owed. `credit` reverts unless the deposit has already landed.
- A post pays out at most once. Credit, then either release or refund; never both, never twice.
- Every release pays exactly 90% to the winner and keeps the remaining 10% as revenue owed to
  REGENT stakers. A refund pays the asker on the same 90/10 split. The revenue owed can only go to
  the staking contract, whose address is fixed at deployment and cannot be changed.
- A refund is refused until thirty days have passed since the deposit was recorded, and after that
  anyone at all may call it. Getting an asker's money back never depends on the operator running.
  The thirty days open the refund; they do not close the release. After them, whichever of a
  release and a refund lands first decides the post, and the other reverts.
- Besides payouts and the push to the staking contract, there is no other way for USDC to leave:
  no sweep, no pause, no upgrade, no owner withdrawal.
  The contract holds no ETH and has no way to receive any.

What the contract cannot check, and therefore accepts on trust: that the operator attributed a
deposit to the right post, and that it released to the address that actually answered. A stolen
operator key can misdirect the 90% share of everything in escrow except the revenue owed: posts
already credited, and unattributed balance it first credits to a post of its own. It cannot mint,
cannot change the split, and cannot take the stakers' share. Replacing the operator stops the old
key from then on; it does not undo payouts already made.

`WinnerIsPayer()` compares addresses only. It stops a release to the exact wallet that paid, not to
another wallet the asker controls.

The owner is a separate address. It can only point the escrow at a new operator address
(`setOperator`) — useful if the server key is rotated or compromised — and hand ownership on in two
steps (`transferOwnership` then `acceptOwnership` by the new owner). The owner has no way to
withdraw, but because it chooses the operator it ultimately decides who attributes deposits and
names winners.

USDC that arrives without an x402 flow behind it, or an overpayment, simply sits in the contract as
unattributed balance. It is recoverable the same way as anything else: the operator credits it to a
fresh post id with the sender as payer, and thirty days later that post can be refunded.

## Deploy

Set the environment first:

| Variable            | Meaning                                                                           |
| ------------------- | --------------------------------------------------------------------------------- |
| `STAKING`           | The REGENT revenue staking contract the 10% is pushed into. Required.             |
| `OPERATOR`          | The Patchbay server address allowed to credit and release. Required.               |
| `OWNER`             | The address that owns the escrow from construction. Required.                      |
| `USDC`              | Token address. Optional; defaults to Base mainnet USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. |
| `BASE_RPC_URL`      | Base mainnet RPC endpoint.                                                        |
| `ETHERSCAN_API_KEY` | Used by `--verify`.                                                               |

Then, from this directory:

```sh
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

Add the sender the deployment should be signed by, for example `--ledger` for a hardware wallet or
`--account <name>` for a Foundry keystore entry. The Ledger still signs; it is not the owner unless
`OWNER` equals the signer. The script prints the deployed address along with the token, staking
contract, operator and owner it was given. `OWNER` is the owner from construction.

## What the server calls

`credit` and `release` are operator-only and revert with `NotOperator()` for anyone else; `refund`
is open to any caller once the delay has passed, and `pushRevenue` is open to any caller. Amounts are
USDC base units (6 decimals), so 1 USDC is `1000000`. `postId` is the 32-byte id the server derives
from the report, so one report has one post id and can only be credited once.

```solidity
function credit(bytes32 postId, address payer, uint96 amount) external;
function release(bytes32 postId, address winner) external;
function refund(bytes32 postId) external;
function pushRevenue() external returns (uint256 amount);
```

`credit` records that `amount` of the USDC already held belongs to `postId`, paid by `payer`. Call
it only after the x402 settlement is confirmed on-chain. It moves no money.

`release` pays `winner` 90% of the post's amount and adds the remaining 10% to `revenueOwed`. The
winner's share rounds down, so the two always add up to exactly the credited amount. The winner may
not be the payer, and neither the payer nor the winner may be the escrow itself.

`refund` sends 90% of the post's amount back to the payer and adds the remaining 10% to
`revenueOwed`, the same split a release uses. It reverts with `RefundTooEarly()` until `REFUND_DELAY` (30 days)
has passed since the deposit was recorded, and after that anyone may call it — the caller pays only
the gas. `REFUND_DELAY` is a public constant.

`pushRevenue` deposits all of `revenueOwed` into the staking contract with `depositUSDC`, tagged
`patchbay.escrow` (`SOURCE_TAG`), and returns the amount. It reverts with `NothingOwed()` when
nothing is owed, and with the staking contract's own error while that contract is paused; the
revenue then stays owed for a later push.

Events, in the order a post produces them:

```solidity
event Credited(bytes32 indexed postId, address indexed payer, uint96 amount, uint64 fundedAt);
event Released(bytes32 indexed postId, address indexed winner, uint256 winnerAmount, uint256 revenueAmount);
event Refunded(bytes32 indexed postId, address indexed payer, uint256 payerAmount, uint256 revenueAmount);
event RevenuePushed(address indexed caller, uint256 amount);
event OperatorChanged(address indexed previousOperator, address indexed newOperator);
```

Reads the server may find useful:

```solidity
function posts(bytes32 postId) external view returns (address payer, uint96 amount, uint8 status, uint64 fundedAt);
function totalCredited() external view returns (uint256);
function revenueOwed() external view returns (uint256);
function usdc() external view returns (address);
function staking() external view returns (address);
function operator() external view returns (address);
```

`status` is `0` never credited, `1` funded, `2` released, `3` refunded. `fundedAt` is the moment
the deposit was recorded; a refund is possible from `fundedAt + REFUND_DELAY` onwards. Unattributed
balance is `usdc.balanceOf(escrow) - totalCredited() - revenueOwed()`.

Revert reasons the server should recognise:

| Error                    | Meaning                                                             |
| ------------------------ | ------------------------------------------------------------------- |
| `NotOperator()`          | The caller is not the operator address.                             |
| `PostAlreadyCredited()`  | That post id is already credited. On a retry, read `posts(postId)`: the same payer and amount means the earlier credit landed; anything else needs a person. |
| `PostNotFunded()`        | The post was never credited, or has already been released/refunded. |
| `AmountExceedsBalance()` | The deposit has not landed yet, or the amount is too large.         |
| `ZeroAddress()`          | A zero address was passed.                                          |
| `ZeroAmount()`           | The amount was zero.                                                |
| `WinnerIsPayer()`        | The winner address is the asker who paid.                           |
| `EscrowIsParty()`        | The escrow's own address was named as the payer or the winner.      |
| `RefundTooEarly()`       | Fewer than thirty days have passed since the deposit was recorded.  |
| `NothingOwed()`          | A push found no revenue owed.                                       |

## Checks

```sh
forge build
forge fmt --check
forge test
slither . --filter-paths "lib/"
```

`script/Sanity.s.sol` walks a deposit through credit → release and a second through credit → refund
against real Base USDC on a local fork, then pushes the revenue kept into the real staking contract. It is a simulation, never broadcast:

```sh
forge script script/Sanity.s.sol --rpc-url $BASE_RPC_URL
```

# PatchbayOffersEscrow

A second USDC escrow on Base mainnet, for Patchbay Offers bids only. It shares no money with
`PatchbayEscrow`. The design was approved by Sean on 5 October 2026 (HQ 98: 1 a, 2 a, 3 a); the
proposal is `docs/handoffs/offers-commitment-escrow-proposal-2026-10-05.md` in the Regent workspace.

Each bid's USDC sits here from the moment it competes until Patchbay settles it:

- The bidder's wallet signs one USDC `ReceiveWithAuthorization` (EIP-3009) made out to this escrow
  for the bid amount, with the bid id as its nonce. The operator submits it with `commit`. The
  signature fixes the amount and the bid id, so Patchbay cannot attribute the money to another bid.
  The form that takes the signature as bytes is used, so smart-contract wallets (ERC-1271) can bid.
- A bid that loses, is passed over or never runs goes back in full with `release`.
- Moving a queued bid to active is only a change in Patchbay's records. Its commitment carries on.
- When a placement ends, `settle` splits its bid: `returned` goes back to the bidder, `consumed` and
  `forfeited` are kept as revenue. The three must add up to the bid.
- 14 days after a commit, anyone may `reclaim` a bid that is still unsettled. It goes back to the
  bidder in full, so getting the money back never depends on Patchbay running.
- Anyone may `pushRevenue`, which deposits the revenue kept into the REGENT revenue staking
  contract, tagged `patchbay.offers`. A paused staking contract holds up only the push.

What the contract guarantees, whatever the operator does: one commitment per bid id, ended at most
once (released, settled or reclaimed); a settlement's parts add up to the bid; returned USDC goes
only to the wallet that committed it; revenue goes only to the staking contract fixed at deployment,
with no setter; and the escrow always holds exactly the open commitments plus the revenue owed. There
is no sweep, pause, upgrade or owner withdrawal. The owner can only replace the operator.

What it trusts Patchbay for: which bid won, the pro-rata refund arithmetic, and that a moderator's
removal returns nothing. A stolen operator key could misallocate a bid between returned and revenue,
but could never send money anywhere except back to its bidder or to the staking contract. Every
settlement carries the bid id, so anyone can check it against Patchbay's placement history.

A repeat press on the same quote signs the same bid, so its second commit reverts and nothing moves
twice. A fresh press is a new bid. Neither needs the button to be gated.

## Deploy

| Variable       | Meaning                                                           |
| -------------- | ----------------------------------------------------------------- |
| `OPERATOR`     | The Patchbay server address allowed to commit, release and settle. |
| `OWNER`        | The address that owns the escrow from construction.               |
| `BASE_RPC_URL` | Base mainnet RPC endpoint.                                        |

USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`) and the REGENT revenue staking contract
(`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`) are fixed in the script. Deploying needs a separate
go from Sean.

```sh
forge script script/DeployOffers.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

## What the server calls

```solidity
function commit(bytes32 bidId, address payer, uint96 amount, uint256 validAfter, uint256 validBefore, bytes calldata signature) external;
function release(bytes32 bidId) external;
function settle(bytes32 bidId, uint256 returned, uint256 consumed, uint256 forfeited) external;
function reclaim(bytes32 bidId) external;
function pushRevenue() external returns (uint256 amount);
function commitments(bytes32 bidId) external view returns (address payer, uint96 amount, uint8 status, uint64 committedAt);
function totalCommitted() external view returns (uint256);
function revenueOwed() external view returns (uint256);
```

`commit`, `release` and `settle` are operator-only. `status` is `0` none, `1` committed,
`2` released, `3` settled, `4` reclaimed. Amounts are USDC base units; Patchbay bids in whole
hundredths (10,000 base units).

```solidity
event Committed(bytes32 indexed bidId, address indexed payer, uint96 amount, uint64 committedAt);
event Released(bytes32 indexed bidId, address indexed payer, uint256 amount);
event Settled(bytes32 indexed bidId, address indexed payer, uint256 returned, uint256 consumed, uint256 forfeited);
event Reclaimed(bytes32 indexed bidId, address indexed payer, uint256 amount, address indexed caller);
event RevenuePushed(address indexed caller, uint256 amount);
event OperatorChanged(address indexed previousOperator, address indexed newOperator);
```

| Error               | Meaning                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `NotOperator()`     | The caller is not the operator address.                                 |
| `AlreadyCommitted()`| That bid id already has a commitment. Read `commitments(bidId)`.        |
| `NotCommitted()`    | The bid was never committed, or has already been released, settled or reclaimed. |
| `PartsDoNotAddUp()` | `returned + consumed + forfeited` is not the bid amount.                |
| `ReclaimTooEarly()` | Fewer than 14 days have passed since the commit.                        |
| `ZeroAddress()`     | A zero address was passed.                                              |
| `ZeroAmount()`      | The amount was zero.                                                    |
| `NothingOwed()`     | A push found no revenue owed.                                           |

A failed USDC authorization (expired, already used, wrong signature, or the bidder's USDC is gone)
reverts with USDC's own message, and nothing moves: the bid is unfunded.

`script/SanityOffers.s.sol` walks three bids through commit → settle, commit → release and
commit → reclaim against real Base USDC on a local fork, then pushes the revenue into the real
staking contract. It is a simulation, never broadcast:

```sh
forge script script/SanityOffers.s.sol --rpc-url $BASE_RPC_URL
```
