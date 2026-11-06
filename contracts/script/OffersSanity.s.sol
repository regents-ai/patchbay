// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegentOffers, IRegentRevenueStaking} from "../src/RegentOffers.sol";

/// @title OffersSanity
/// @notice Walks two bids, each approved then sent by its own bidder, through the real Base mainnet USDC on a local fork: the first is
///         placed, then replaced an hour later by the second, which runs its full length; both
///         bidders and the venue are paid out and the protocol share goes into the real REGENT
///         revenue staking contract. A third bid is never placed and comes back after its place-by
///         time. Simulation only; never broadcast.
/// @dev Run with: forge script script/OffersSanity.s.sol --rpc-url https://mainnet.base.org
contract OffersSanity is Script, StdCheats {
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IRegentRevenueStaking internal constant STAKING = IRegentRevenueStaking(0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5);

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint32 internal constant LENGTH = 72 hours;

    RegentOffers internal offers;
    address internal operator;

    function run() external {
        operator = makeAddr("operator");
        address owner = makeAddr("owner");
        address payout = makeAddr("payout");
        offers = new RegentOffers(USDC, STAKING, 1000, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, makeAddr("admin"), operator, makeAddr("moderator"), payout, 1_000_000, LENGTH);
        console2.log("offers:", address(offers));

        address alice = makeAddr("regent-offers-sanity-alice-1106");
        address bob = makeAddr("regent-offers-sanity-bob-1106");
        deal(address(USDC), alice, 200_000_000);
        deal(address(USDC), bob, 200_000_000);

        // Alice's 72 USDC bid is placed; an hour later Bob's 144 USDC bid replaces it.
        bytes32 first = _bid(alice, 72_000_000, 1);
        vm.prank(operator);
        offers.place(first);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bytes32 second = _bid(bob, 144_000_000, 2);
        vm.prank(operator);
        offers.place(second);
        // One hour of 72 shown: 1 USDC paid, 71 back to Alice.
        require(offers.owed(alice) == 71_000_000, "alice's unused time was not owed back");

        // Bob's placement runs its length and anyone finishes it.
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(second);

        // A third bid is never placed; after its place-by anyone hands it back.
        bytes32 third = _bid(alice, 5_000_000, 3);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        offers.withdraw(third);

        uint256 aliceBefore = USDC.balanceOf(alice);
        offers.payOut(alice);
        require(USDC.balanceOf(alice) == aliceBefore + 76_000_000, "alice was not paid 71 + 5");
        offers.payOut(payout);
        // Paid in all: 1 + 144 = 145 USDC; the venue keeps 90%.
        require(USDC.balanceOf(payout) == 130_500_000, "venue was not paid 130.5");

        uint256 stakingBefore = USDC.balanceOf(address(STAKING));
        offers.pushRevenue();
        require(USDC.balanceOf(address(STAKING)) == stakingBefore + 14_500_000, "staking did not receive 14.5");
        require(USDC.balanceOf(address(offers)) == 0, "offers kept USDC after every payout");
        console2.log("all ok: alice", USDC.balanceOf(alice), "venue", USDC.balanceOf(payout));
    }

    function _bid(address from, uint96 amount, uint256 salt) internal returns (bytes32 id) {
        RegentOffers.Terms memory t = RegentOffers.Terms({
            venue: VENUE,
            slot: SLOT,
            lane: 0,
            wordingHash: keccak256(abi.encode("wording", salt)),
            amount: amount,
            length: LENGTH,
            placeBy: uint64(vm.getBlockTimestamp() + 30 minutes),
            salt: bytes32(salt)
        });
        vm.startPrank(from);
        USDC.approve(address(offers), amount);
        id = offers.bid(t);
        vm.stopPrank();
    }
}
