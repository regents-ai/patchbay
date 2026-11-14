// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";
import {IAgentOfferMarket} from "./IAgentOfferMarket.sol";
import {AgentOfferFactory} from "./AgentOfferFactory.sol";

/// @title AgentOfferStakingPayout
/// @notice The payout wallet of one publisher's Offer market, for a publisher whose earnings all
///         go into REGENT revenue staking: Patchbay's. Anyone may call `pushEarnings`, which
///         takes what the market owes this contract and deposits it into the same staking contract
///         the market's protocol fee goes to. The money can go nowhere else.
/// @dev A market credits its publisher's share to its fixed payout address, and only that address
///      can claim it. Naming the staking contract itself as payout would strand the money, since
///      staking never claims, and a plain transfer to staking would not be recorded as revenue. So
///      this contract is the payout address, and turns each claim into a `depositUSDC`.
///
///      There is no owner, admin, upgrade, sweep or setting; the market, USDC and staking contract
///      are fixed at construction. They are read from the factory for the publisher it is given,
///      so this contract can only serve the market that factory creates for that publisher, with
///      the token and staking contract that market itself uses. The market's address is known
///      before the market exists (`AgentOfferFactory.predictMarket`), which is what lets this
///      contract be deployed first and then named as payout in `createMarket`. Nothing at
///      construction needs code at the market address.
///
///      Deploy order: the factory; this contract with the factory and the publisher; then the
///      publisher calls `createMarket` with this contract's address. Afterwards check that
///      `factory.marketOf(publisher) == market` and that the market's `payout()` is this contract.
///      A market created by any other address, or by another factory, would credit this contract
///      earnings it never claims.
///
///      Every push deposits this contract's whole USDC balance, so nothing can be stranded here:
///      USDC sent here by anyone goes into staking with the next push, as a gift to staking.
contract AgentOfferStakingPayout is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The source tag every push carries, so the staking books tell the publisher's share
    ///         apart from the market's protocol fee, which is tagged `agent.offers`.
    // casting to 'bytes32' is safe because the 19-character literal fits in 32 bytes
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("agent.offers.payout");

    /// @notice The market whose payout address this contract is. Never changes.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IAgentOfferMarket public immutable market;

    /// @notice The USDC token the market pays in. Never changes.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract every push deposits into: the one the market
    ///         pushes its protocol fee into. Never changes.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice Emitted when a push deposits into staking.
    /// @param caller Whoever called `pushEarnings`.
    /// @param claimedUSDC What the market owed this contract and sent it in this push.
    /// @param depositedUSDC What was deposited: `claimedUSDC` plus whatever was already held.
    event EarningsPushed(address indexed caller, uint256 claimedUSDC, uint256 depositedUSDC);

    /// @notice Thrown by the constructor for a zero publisher, which no market can ever have.
    error InvalidConfiguration();

    /// @notice Thrown when the market owes this contract nothing and it holds no USDC.
    error NothingToPush();

    /// @notice Fixes the market `factory` creates, or will create, for `publisher`, together with
    ///         that factory's USDC and staking contract.
    /// @param factory The offer factory the publisher creates its market with.
    /// @param publisher The publisher whose market this contract will be the payout of.
    constructor(AgentOfferFactory factory, address publisher) {
        if (publisher == address(0)) revert InvalidConfiguration();
        market = IAgentOfferMarket(factory.predictMarket(publisher));
        usdc = IERC20(factory.BASE_USDC());
        staking = factory.staking();
    }

    /// @notice Claims everything the market owes this contract and deposits it, with any USDC this
    ///         contract already holds, into the staking contract, tagged `agent.offers.payout` with
    ///         the market's address as the reference. Anyone may call it.
    /// @dev Claims only when the market owes something, so USDC already held is pushed even when
    ///      nothing new is owed. While the staking contract is paused the deposit reverts, and with
    ///      it the claim, so the earnings stay owed in the market. The staking contract is trusted
    ///      to pull exactly the amount it is approved for, as USDC's `transferFrom` does.
    /// @return depositedUSDC What was deposited.
    function pushEarnings() external nonReentrant returns (uint256 depositedUSDC) {
        uint256 claimedUSDC = market.claimable(address(this));
        depositedUSDC = claimedUSDC + usdc.balanceOf(address(this));
        // Zero is exactly "nothing to push". USDC anyone sends here only makes a push larger.
        // slither-disable-next-line incorrect-equality
        if (depositedUSDC == 0) revert NothingToPush();

        emit EarningsPushed(msg.sender, claimedUSDC, depositedUSDC);

        if (claimedUSDC != 0) {
            // The market sends exactly the credit read above; the deposit below pulls it.
            // slither-disable-next-line unused-return
            market.claim(address(this)); // forge-lint: disable-line(unused-return)
        }
        usdc.forceApprove(address(staking), depositedUSDC);
        // The staking contract records what it received itself; USDC moves the exact amount.
        // slither-disable-next-line unused-return
        staking.depositUSDC(depositedUSDC, SOURCE_TAG, bytes32(uint256(uint160(address(market))))); // forge-lint: disable-line(unused-return)
    }
}
