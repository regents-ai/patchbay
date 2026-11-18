# PatchbayEscrow

A single USDC escrow contract on Base mainnet for Patchbay's pay-to-special forum posts.

The asker names the amount and pays it over x402. The x402 settlement is an ordinary USDC transfer
whose `payTo` is this contract, so the deposit arrives with nothing on it to say which post it was
for. The Patchbay server confirms the settlement off-chain and then tells the contract, on-chain,
that a given amount now belongs to a given post. When the asker marks an answer correct, the server
releases the post: the winning answer receives 90% and the escrow keeps the other 10% as Regents
Labs revenue. If no answer is ever chosen, then thirty days after the deposit was recorded anyone
may send the money back to the asker, who receives 90% of it on the same split. Only the operator or
the Safe (the owner) may push the revenue kept into the REGENT revenue staking contract, which shares
each deposit between REGENT stakers, by the staked share of the total supply, and its treasury. The
copy live on Base since 4 Oct 2026, at `0x170FA3C1bD90220AF4c4609078a1016d01be7681`, was deployed
before this rule and is unchanged.

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
(`setOperator`), useful if the server key is rotated or compromised; push the revenue kept into the
staking contract; and hand ownership on in two steps (`transferOwnership` then `acceptOwnership` by
the new owner). The owner has no way to
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
| `OPERATOR`          | The Patchbay server address allowed to credit, release and push the revenue. Required. |
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
is open to any caller once the delay has passed; only the operator or the Safe (the owner) may call
`pushRevenue`, which reverts with `NotStakingSender()` for anyone else. Amounts are USDC base units
(6 decimals), so 1 USDC is `1000000`. `postId` is the 32-byte id the server derives
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
| `NotStakingSender()`     | The caller of `pushRevenue` is neither the operator nor the owner.  |
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
against real Base USDC on a local fork, then, as the operator, pushes the revenue kept into the real staking contract. It is a simulation, never broadcast:

```sh
forge script script/Sanity.s.sol --rpc-url $BASE_RPC_URL
```

# Agent offer markets

`AgentOfferFactory` and `AgentOfferMarket` (interface `IAgentOfferMarket`) are where agent Offers are
bought on Base; `AgentOfferStakingPayout` is the payout address of Patchbay's own market. They are
built and tested here and **not deployed yet**; `script/DeployOffers.s.sol` deploys them (see
"Deploy the offer contracts" below). The factory refuses to deploy anywhere but Base mainnet (chain
8453, with Circle's native USDC at `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`), so they cannot be
tried on Base Sepolia as written. The tests set the chain id to 8453 and place a stand-in token at
that address.

## The model

- A **publisher** is the site that shows Offers to agents and is paid for it. Patchbay is
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
  its credit to another wallet of its own. The fee leaves only through `pushRevenue()`, which only
  the operator or the Safe may call (see "Who can do what") and which deposits into the REGENT
  revenue staking contract tagged `agent.offers`, with the market's address as the reference. While
  staking is paused, only the push waits.
- The market keeps its books by amounts:
  `usdc.balanceOf(market) >= totalLeaseDeposits() + totalClaimable() + revenueOwed()` at all times.
  USDC sent straight to a market is nobody's credit and stays there; there is no sweep.
- The protocol fee is set once in the factory (1,000 basis points, 10%, for the planned deployment)
  and can be at most 2,000 (20%), so a publisher always keeps at least 80% of what it earns.

## Who can do what

- **Factory owner (the Safe):** admits and removes publishers, sets the operator, and may send to
  staking. Removing a publisher stops it creating a market; a market already created keeps running.
  Beyond sending to staking, the owner has no way to touch any market or its money.
- **Operator:** one address, set when the factory is deployed and replaceable only by the owner
  (`setOperator`, which emits `OperatorSet`). Only the operator or the Safe may send to staking:
  `pushRevenue` on every market of the factory and `pushEarnings` on the staking payout ask the
  factory's `maySendToStaking(caller)`, and refuse anyone else, a publisher and a payout wallet
  included, with `NotStakingSender()`. Neither call can send money anywhere but the staking
  contract.
- **Publisher:** creates placements, signs admissions and terminates placements. A termination
  refunds every live lease from that moment, one slot per `settleTerminated` call (anyone may make
  it), however late. A stolen publisher key can do no more than this: it cannot redirect earnings or
  take deposits.
- **Payout wallet:** fixed when the market is created and never changed. If it is lost, only the
  publisher's own earnings are stranded; buyers' refunds are credited to buyers. The publisher would
  then terminate its placements and, with the owner admitting a new publisher address, create a new
  market with a new payout wallet. A Safe is the better choice for the payout wallet. Patchbay's is
  the staking payout contract below, which nobody controls.
- **Anyone:** buys (with an admission) and settles run-out or terminated leases.

A market records the factory that initialized it (`factory()`). Anyone can clone the public
implementation, but a clone the factory did not create answers to whoever initialized it, never to
the factory's operator or owner, and is not listed in `marketOf`.

Lease lengths are capped at 365 days, the step at 10,000 basis points (a buyout never has to pay more
than double), and every bound is checked when a placement is created.

## Patchbay's earnings into staking

Patchbay keeps none of what its own market earns: its share goes into the REGENT revenue staking
contract, like the protocol fee. A market credits only its fixed payout address and only that
address can claim, so naming the staking contract as payout would strand the money (staking never
claims), and a plain transfer to staking is not recorded as revenue. Patchbay's payout address is
therefore `AgentOfferStakingPayout`, a contract that does one thing:

- `pushEarnings()` claims everything the market owes it and, in the same call, deposits it into the
  staking contract with `depositUSDC`, tagged `agent.offers.payout` with the market's address as the
  reference. The fee keeps its own tag, `agent.offers`, so the staking books tell the two apart.
  Only the operator or the Safe may call it, as for `pushRevenue`; it returns the amount deposited.
- Every push deposits the contract's whole USDC balance, so nothing can be stranded in it: USDC
  anyone sends it goes into staking with the next push. `EarningsPushed(caller, claimedUSDC,
  depositedUSDC)` shows how much of a push came from the market. The market is asked only when it
  owes something; with nothing owed and nothing held, the push reverts with `NothingToPush()`.
- While staking is paused the deposit reverts, and the whole push with it: the earnings stay owed in
  the market for a later push.
- It has no owner, no settings of its own and no way to send money anywhere but the staking
  contract; who may push is the factory's rule. Its factory is fixed at deployment, and its market,
  USDC and staking contract are read from that factory for the publisher it is given, so it can only
  serve the market that factory creates for that publisher, with the token and staking contract that
  market itself uses.

Deploy order, one transaction each:

1. Deploy `AgentOfferFactory` with its owner and operator, admitting Patchbay's publisher address.
2. Read `factory.predictMarket(publisher)`: the address Patchbay's market will have.
3. Deploy `AgentOfferStakingPayout(factory, publisher)` from any address, and check that its
   `market()` is that predicted address and its `staking()` is the factory's.
4. From the publisher address, call `factory.createMarket(<the payout contract>)`.
5. Check that `factory.marketOf(publisher)` is the payout contract's `market()` and that the
   market's `payout()` is the payout contract. Step 4 must come from that publisher on that factory:
   a market created by any other address, or by another factory, would credit the payout contract
   earnings it never claims.

The publisher's signing key only creates and terminates placements and signs admissions; it never
holds or receives money, and it is not the operator unless the owner names it so. Only the operator
or the Safe may call `pushRevenue` and `pushEarnings`, at any time, and neither can send money
anywhere but staking.

## Deploy the offer contracts

`script/DeployOffers.s.sol` performs the five steps above in order and stops with a reason if a check
fails. Every transaction is sent from the publisher address, since step 4 must come from it; the
factory and the payout contract give whoever deploys them no role. The publisher pays the gas of
three transactions, so it needs a little ETH on Base first. The script stops before sending
anything on a chain other than Base mainnet or when an address is zero, and the factory refuses a fee
above 2,000.

| Variable            | Meaning                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------ |
| `OFFERS_ADMIN`      | The factory's owner (the Safe): admits and removes publishers, sets the operator.          |
| `OFFERS_OPERATOR`   | The operator: with the owner, the only address that may send to staking.                   |
| `OFFERS_PUBLISHER`  | Patchbay's publisher address, whose key the site holds as `PATCHBAY_OFFERS_PUBLISHER_KEY`. |
| `OFFERS_STAKING`    | The REGENT revenue staking contract the fee and Patchbay's earnings go into.               |
| `OFFERS_FEE_BPS`    | The protocol fee in basis points: 1000 for the planned deployment.                         |
| `BASE_RPC_URL`      | Base mainnet RPC endpoint.                                                                 |
| `ETHERSCAN_API_KEY` | Used by `--verify`.                                                                        |

Then, from this directory, signing as the publisher (a Foundry keystore entry holding its key, or
`--ledger --sender <publisher>`; no key is ever written in the repository):

```sh
forge script script/DeployOffers.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify --account <publisher keystore name>
```

The script logs the factory, its implementation, owner, operator, staking contract and fee, the
staking payout contract, and the market with its publisher and payout. The market's address and the
block its `MarketCreated` transaction landed in are what the site needs (`platform/docs/GO_LIVE.md`,
"Offers").
Without `--broadcast` the same command only simulates.

## Checks

The same commands as above. `test/AgentOfferMarket.t.sol` holds the unit, fuzz, reentrancy and
invariant suites; `test/AgentOfferFactory.t.sol` the factory's, including who may send to staking,
a clone made outside the factory, and a permit for one market being refused by another;
`test/AgentOfferStakingPayout.t.sol` the staking payout's, including a staking contract that calls
back mid-deposit; `test/DeployOffers.t.sol` runs the deploy script and checks what it leaves wired,
sells on it and pushes everything earned into staking.

`test/AgentOfferForkRehearsal.t.sol` rehearses the whole money path on a local fork of Base mainnet
pinned to one block, with Circle's real USDC and the live REGENT revenue staking contract: the
factory, Patchbay's market paying its staking payout contract and a second market paying a plain
wallet, sales, a buyout, a lease run to its end, a placement terminated early, every claim, the fees
and Patchbay's earnings pushed into staking by the operator, and every unit accounted for.
It logs the gas of each step as a transaction of its own. Nothing is broadcast. It is skipped
unless `BASE_RPC_URL` is set, so `forge test` stays offline:

```sh
BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/AgentOfferForkRehearsal.t.sol -vv
```
