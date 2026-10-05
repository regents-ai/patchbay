// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {PatchbayOffersEscrow} from "../src/PatchbayOffersEscrow.sol";

/// @notice The parts of Base USDC the walk-through reads to build an authorization.
interface IUSDCDomain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @title SanityOffers
/// @notice Walks three Offers bids through the escrow against real Base mainnet USDC on a local
///         fork: one signed in with `receiveWithAuthorization` and settled as a buyout, one released
///         after losing, one reclaimed after 14 days. Then it pushes the revenue kept into the real
///         REGENT revenue staking contract. Simulation only; never broadcast.
/// @dev Run with: forge script script/SanityOffers.s.sol --rpc-url $BASE_RPC_URL
contract SanityOffers is Script, StdCheats {
    /// @notice Circle's native USDC on Base mainnet.
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice The REGENT revenue staking contract on Base mainnet.
    IRegentRevenueStaking internal constant STAKING = IRegentRevenueStaking(0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5);

    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @notice 10.00 USDC, in 6-decimal base units.
    uint96 internal constant BID = 10_000_000;

    PatchbayOffersEscrow internal escrow;
    address internal operator;
    address internal bidder;
    uint256 internal bidderKey;

    /// @notice Deploys the escrow on the fork and checks every way a bid's USDC can leave it.
    function run() external {
        operator = makeAddr("operator");
        (bidder, bidderKey) = makeAddrAndKey("bidder");
        escrow = new PatchbayOffersEscrow(USDC, STAKING, operator, makeAddr("owner"));
        console2.log("escrow:", address(escrow));
        deal(address(USDC), bidder, BID * 3);

        // A buyout: 6.00 back for the unused time, 4.00 kept for the time shown.
        _commit(keccak256("bid-1"));
        require(USDC.balanceOf(address(escrow)) == BID, "commit did not pull the bid");
        require(IUSDCDomain(address(USDC)).authorizationState(bidder, keccak256("bid-1")), "nonce not spent");
        vm.prank(operator);
        escrow.settle(keccak256("bid-1"), 6_000_000, 4_000_000, 0);
        require(USDC.balanceOf(bidder) == BID * 2 + 6_000_000, "settle did not return 6.00");
        console2.log("settle ok: revenue owed", escrow.revenueOwed());

        // A losing bid comes back in full.
        _commit(keccak256("bid-2"));
        vm.prank(operator);
        escrow.release(keccak256("bid-2"));
        require(USDC.balanceOf(bidder) == BID * 2 + 6_000_000, "release did not return the bid");
        console2.log("release ok");

        // An unsettled bid, 14 days on, sent back by a passer-by.
        _commit(keccak256("bid-3"));
        vm.warp(block.timestamp + escrow.RECLAIM_DELAY());
        vm.prank(makeAddr("a passer-by"));
        escrow.reclaim(keccak256("bid-3"));
        require(USDC.balanceOf(bidder) == BID * 2 + 6_000_000, "reclaim did not return the bid");
        console2.log("reclaim ok");

        uint256 stakingBefore = USDC.balanceOf(address(STAKING));
        vm.prank(makeAddr("another passer-by"));
        escrow.pushRevenue();
        require(USDC.balanceOf(address(STAKING)) == stakingBefore + 4_000_000, "staking did not receive 4.00");
        require(USDC.balanceOf(address(escrow)) == 0, "escrow retained funds after the push");
        console2.log("push ok: staking received", USDC.balanceOf(address(STAKING)) - stakingBefore);
    }

    /// @dev Signs a 2-minute authorization for `bidId` as the bidder's wallet would, and commits it.
    function _commit(bytes32 bidId) internal {
        uint256 validBefore = block.timestamp + 2 minutes;
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, bidder, address(escrow), BID, 0, validBefore, bidId)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IUSDCDomain(address(USDC)).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bidderKey, digest);

        vm.prank(operator);
        escrow.commit(bidId, bidder, BID, 0, validBefore, abi.encodePacked(r, s, v));
    }
}
