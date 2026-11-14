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

# Agent offer markets

`AgentOfferFactory` and `AgentOfferMarket` (interface `IAgentOfferMarket`) are where agent Offers are
bought on Base. They are built and tested here and **not deployed**: there is no deploy script for
them, and the factory refuses to deploy anywhere but Base mainnet (chain 8453, with Circle's native
USDC at `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`), so they cannot be tried on Base Sepolia as
written. The tests set the chain id to 8453 and place a stand-in token at that address.

## The model

- A **publisher** is the operator that shows Offers to agents and is paid for it. Patchbay is
  admitted from the start; the factory's owner admits others later. Each admitted publisher creates
  **one market**, a clone of one fixed implementation that the factory deploys itself, at an address
  `predictMarket(publisher)` gives in advance.
- A **placement** is one surface a publisher sells: a number of slots (`capacity`), a lease length
  (`durationSeconds`), a buyout step (`minBumpBps`), a floor price (`floorUSDC`) and an admission
  policy (`policyHash`). Patchbay's own settings are 3 slots, 72 hours and a 10% step; they are not
  rules of the market. A placement's terms never change. To change them the publisher terminates it,
  or lets its leases run out, and creates a new one. The market cannot tell that two placements are
  the same place on a page, so the publisher must not sell a replacement while the old one is open.
- A **lease** is one slot bought for one full term. On an empty slot, or one whose lease has run out,
  it costs at least the floor. While a lease is live, a buyout must pay at least the lease's payment
  plus the step, rounded up to the next base unit; the buyer gets a fresh full term, and the replaced
  buyer is credited the unused share of its payment, `paid × seconds left ÷ duration`, rounded down.
  A purchase at the exact second a lease ends meets a run-out lease: the floor applies and nothing is
  refunded.
- Every purchase carries the publisher's **admission**: an EIP-712 signature (or an ERC-1271
  approval from a contract wallet) over the placement, slot, source, buyer, campaign, policy, amount,
  the slot's lease nonce and a deadline, in a domain bound to the chain and that one market's
  address. A slot's nonce counts the leases it has sold and never resets, so two buyers racing for
  the same slot cannot both land, and an admission is used at most once.

## Money

- Nothing is paid out during a purchase. Settling a lease (bought out, run out, or terminated) only
  credits: the refund to the buyer, the earned part to the payout wallet less the protocol fee, and
  the fee to `revenueOwed`. The three always add up to exactly what the lease paid.
- Every credit leaves only through its owner's `claim(recipient)`; a wallet USDC has frozen can send
  its credit to another wallet of its own. The fee leaves only through `pushRevenue()`, which anyone
  may call and which deposits into the REGENT revenue staking contract tagged `agent.offers`, with the
  market's address as the reference. While staking is paused, only the push waits.
- The market keeps its books by amounts:
  `usdc.balanceOf(market) >= totalLeaseDeposits() + totalClaimable() + revenueOwed()` at all times.
  USDC sent straight to a market is nobody's credit and stays there; there is no sweep.
- The protocol fee is set once in the factory (1,000 basis points, 10%, for the planned deployment)
  and can be at most 2,000 (20%), so a publisher always keeps at least 80% of what it earns.

## Who can do what

- **Factory owner:** admits and removes publishers. Removing one stops it creating a market; a market
  already created keeps running. The owner has no way to touch any market or its money.
- **Publisher:** creates placements, signs admissions and terminates placements. A termination
  refunds every live lease from that moment, one slot per `settleTerminated` call (anyone may make
  it), however late. A stolen publisher key can do no more than this: it cannot redirect earnings or
  take deposits.
- **Payout wallet:** fixed when the market is created and never changed. If it is lost, only the
  publisher's own earnings are stranded; buyers' refunds are credited to buyers. The publisher would
  then terminate its placements and, with the owner admitting a new publisher address, create a new
  market with a new payout wallet. A Safe is the better choice for the payout wallet.
- **Anyone:** buys (with an admission), settles run-out or terminated leases, and pushes the fee.

Lease lengths are capped at 365 days, the step at 10,000 basis points (a buyout never has to pay more
than double), and every bound is checked when a placement is created.

## Checks

The same commands as above. `test/AgentOfferMarket.t.sol` holds the unit, fuzz, reentrancy and
invariant suites; `test/AgentOfferFactory.t.sol` the factory's, including a permit for one market
being refused by another.
