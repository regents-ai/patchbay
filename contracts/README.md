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
- Besides payouts and the push to the staking contract, there is no other way for USDC to leave:
  no sweep, no pause, no upgrade, no owner withdrawal.
  The contract holds no ETH and has no way to receive any.

What the contract cannot check, and therefore accepts on trust: that the operator attributed a
deposit to the right post, and that it released to the address that actually answered. A stolen
operator key can misdirect money that is already in escrow, up to the total credited. It cannot
mint, cannot change the split, and cannot take the stakers' share.

The owner is a separate address. It can only point the escrow at a new operator address
(`setOperator`) — useful if the server key is rotated or compromised — and hand ownership on in two
steps (`transferOwnership` then `acceptOwnership` by the new owner). The owner cannot move funds.

USDC that arrives without an x402 flow behind it, or an overpayment, simply sits in the contract as
unattributed balance. It is recoverable the same way as anything else: the operator credits it to a
fresh post id with the sender as payer, and thirty days later that post can be refunded.

## Deploy

Set the environment first:

| Variable            | Meaning                                                                           |
| ------------------- | --------------------------------------------------------------------------------- |
| `STAKING`           | The REGENT revenue staking contract the 10% is pushed into. Required.             |
| `OPERATOR`          | The Patchbay server address allowed to credit, release and refund. Required.       |
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
USDC base units (6 decimals), so 1 USDC is `1000000`. `postId` is any 32-byte id the server picks;
it must be fresh, because a post id can only be credited once.

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
not be the payer.

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
| `PostAlreadyCredited()`  | That post id has been used before. Use a fresh one.                 |
| `PostNotFunded()`        | The post was never credited, or has already been released/refunded. |
| `AmountExceedsBalance()` | The deposit has not landed yet, or the amount is too large.         |
| `ZeroAddress()`          | A zero address was passed.                                          |
| `ZeroAmount()`           | The amount was zero.                                                |
| `WinnerIsPayer()`        | The winner address is the asker who paid.                           |
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
