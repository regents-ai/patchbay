# PatchbayEscrow

A single USDC escrow contract on Base mainnet for Patchbay's pay-to-special forum posts.

The asker names the amount and pays it over x402. The x402 settlement is an ordinary USDC transfer
whose `payTo` is this contract, so the deposit arrives with nothing on it to say which post it was
for. The Patchbay server confirms the settlement off-chain and then tells the contract, on-chain,
that a given amount now belongs to a given post. When the asker marks an answer correct, the server
releases the post: the winning answer receives 90% and the escrow keeps the other 10% as Regents
Labs revenue. If no answer is ever chosen, then thirty days after the deposit was recorded anyone
may send the money back to the asker, who receives 90% of it on the same split. Anyone may push the
revenue kept into the REGENT revenue staking contract, which shares each deposit between REGENT
stakers, by the staked share of the total supply, and its treasury.

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
  REGENT staking. A refund pays the asker on the same 90/10 split. The revenue owed can only go to
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
cannot change the split, and cannot take REGENT staking's share. Replacing the operator stops the old
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

## OfferExchange

**Not deployed.** `src/OfferExchange.sol` is written and tested here only. No network runs it, there
is no deploy script for it, and deploying it needs the founder's go.

A market where bidders pay USDC to have an Offer (a short labelled message, kept by its 32-byte
fingerprint) shown to agents in a spot on a listed site. Every spot has three slots. A bidder buys
time: it names a rate in USDC base units per second and a budget, and holds a slot from the moment
it bids until the budget runs out. A free slot goes to any bid at or above the spot's minimum rate.
With all three taken, a bid must beat the lowest rate by at least 5% and takes that slot; between
equal rates the earlier holder keeps its place. Each holder pays its own rate for the seconds it held.

- An overtaken holder pays for the seconds it held, up to that moment.
- Leaving early (`leave`) charges the seconds held, but never less than a minute, so taking a slot
  and leaving at once is not free.
- The site may take down an Offer it does not want shown (`remove`); the holder pays only the
  seconds it held.
- A hold whose budget has run out is settled by the next bid on its slot, or by anyone with `settle`.

Of every charge, 90% is credited to the site's payout wallet and 10% is kept as revenue for REGENT
staking. The unspent budget, rounding included, is credited back to the bidder. Nothing is paid out
during a bid, leave, removal or settlement: every address takes what it is owed with `withdraw`, so a
frozen wallet only ever holds up its own money. Anyone may push the revenue kept into the staking
contract with `pushRevenue`, tagged `offers.exchange`, as the escrow does.

The owner lists sites and can pause new bids; leaving, removal, settlement, withdrawals and the push
never pause. The owner cannot move money, change the split or change a site's payout wallet. A site's
payout wallet adds the site's spots, removes Offers, and can hand the site to a new wallet; credit
already earned stays with the old one. There is no upgrade, no sweep and no owner withdrawal, so USDC
sent to the contract outside a bid stays there. Time is counted in seconds of the block's timestamp,
never in blocks.

```solidity
function listSite(address payout) external returns (uint256 siteId);                 // owner
function setPaused(bool paused) external;                                            // owner
function addSpot(uint256 siteId, uint96 minRate) external returns (uint256 spotId);  // site
function setPayout(uint256 siteId, address newPayout) external;                      // site
function remove(uint256 spotId, uint256 slot) external;                              // site
function bid(uint256 spotId, bytes32 offerId, uint96 rate, uint96 budget) external returns (uint256 slot);
function leave(uint256 spotId, uint256 slot) external;                               // holder
function settle(uint256 spotId, uint256 slot) external;                              // anyone, once run out
function withdraw() external returns (uint256 amount);
function pushRevenue() external returns (uint256 amount);
function spotHolds(uint256 spotId) external view returns (Hold[3] memory holds, bool[3] memory live);
```

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
