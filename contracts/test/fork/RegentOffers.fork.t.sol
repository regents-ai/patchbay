// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {RegentOffers, IRegentRevenueStaking} from "../../src/RegentOffers.sol";

interface IRealUSDC is IERC20 {
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function pauser() external view returns (address);
    function blacklister() external view returns (address);
    function pause() external;
    function unpause() external;
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external;
}

interface IRealStaking {
    function owner() external view returns (address);
    function setPaused(bool paused) external;
}

/// @title RegentOffersForkTest
/// @notice Against the real Base USDC and the real REGENT staking contract on a local fork of the
///         public Base endpoint. Nothing is broadcast. Each test passes when the real token behaves
///         as RegentOffers assumes. The offline gate leaves this folder out; run it with
///         `make check-contracts-fork` from the repository root, or from this folder with
///         `forge test --match-path 'test/fork/*'`.
/// @dev Labels are unique on purpose: Foundry's plain names, such as "alice", are addresses that
///      are already delegated with EIP-7702 on Base, and real USDC then refuses their signatures.
contract RegentOffersForkTest is Test {
    IRealUSDC internal constant USDC = IRealUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint32 internal constant LENGTH = 72 hours;
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    RegentOffers internal offers;
    address internal owner = makeAddr("regent-offers-fork-owner-1106");
    address internal admin = makeAddr("regent-offers-fork-admin-1106");
    address internal operator = makeAddr("regent-offers-fork-operator-1106");
    address internal moderator = makeAddr("regent-offers-fork-moderator-1106");
    address internal payout = makeAddr("regent-offers-fork-payout-1106");
    address internal stranger = makeAddr("regent-offers-fork-stranger-1106");
    address internal bidder;
    uint256 internal bidderKey;
    uint256 internal salts;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        (bidder, bidderKey) = makeAddrAndKey("regent-offers-fork-bidder-1106");
        offers = _market();
        deal(address(USDC), bidder, 1_000_000_000);
    }

    function _market() internal returns (RegentOffers o) {
        o = new RegentOffers(USDC, IRegentRevenueStaking(STAKING), 1000, owner);
        vm.prank(owner);
        o.addVenue(VENUE, admin, operator, moderator, payout, 1_000_000, LENGTH);
    }

    function _terms(bytes32 slot, uint96 amount) internal returns (RegentOffers.Terms memory t) {
        t = RegentOffers.Terms({
            venue: VENUE,
            slot: slot,
            lane: 0,
            wordingHash: keccak256("wording"),
            amount: amount,
            length: LENGTH,
            placeBy: uint64(vm.getBlockTimestamp() + 1 hours),
            salt: bytes32(++salts)
        });
    }

    function _sign(uint256 key, address from, address to, RegentOffers.Terms memory t, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, from, to, t.amount, uint256(0), validBefore, keccak256(abi.encode(t)))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _bid(bytes32 slot, uint96 amount) internal returns (bytes32) {
        RegentOffers.Terms memory t = _terms(slot, amount);
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        return offers.bid(t, bidder, 0, validBefore, _sign(bidderKey, bidder, address(offers), t, validBefore));
    }

    /// The real USDC lets a bidder's signature do one thing only: fund its exact bid on this market.
    function test_fork_a_signature_serves_only_its_own_bid() public {
        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        bytes memory signature = _sign(bidderKey, bidder, address(offers), t, validBefore);
        bytes32 nonce = offers.nonceOf(t);

        // A stranger cannot pull the money to the market without recording the bid.
        vm.prank(stranger);
        vm.expectRevert(bytes("FiatTokenV2: caller must be the payee"));
        USDC.receiveWithAuthorization(bidder, address(offers), t.amount, 0, validBefore, nonce, signature);

        // Nor through the transfer form of the same authorization.
        vm.prank(stranger);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        USDC.transferWithAuthorization(bidder, address(offers), t.amount, 0, validBefore, nonce, signature);

        // Another market with the same venue cannot use it.
        RegentOffers twin = _market();
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        twin.bid(t, bidder, 0, validBefore, signature);

        // Changed terms, payer or time window are refused.
        // (A memory struct assignment is a reference, so each change is undone before the next.)
        t.amount += 1;
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore, signature);
        t.amount -= 1;
        t.placeBy += 1;
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore, signature);
        t.placeBy -= 1;
        t.lane = 1;
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore, signature);
        t.lane = 0;
        t.wordingHash = keccak256("other wording");
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore, signature);
        t.wordingHash = keccak256("wording");
        assertEq(offers.nonceOf(t), nonce);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, stranger, 0, validBefore, signature);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore + 1, signature);

        // The exact bid goes through once, from anyone.
        uint256 before = USDC.balanceOf(bidder);
        vm.prank(stranger);
        offers.bid(t, bidder, 0, validBefore, signature);
        assertEq(USDC.balanceOf(bidder), before - 50_000_000);
        assertTrue(USDC.authorizationState(bidder, nonce));
        vm.expectRevert(RegentOffers.BidExists.selector);
        offers.bid(t, bidder, 0, validBefore, signature);
    }

    /// A bidder can kill a signature before anyone submits it.
    function test_fork_a_bidder_can_cancel_an_unsubmitted_signature() public {
        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        bytes memory signature = _sign(bidderKey, bidder, address(offers), t, validBefore);
        bytes32 nonce = offers.nonceOf(t);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            bidderKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01", USDC.DOMAIN_SEPARATOR(), keccak256(abi.encode(CANCEL_TYPEHASH, bidder, nonce))
                )
            )
        );
        USDC.cancelAuthorization(bidder, nonce, abi.encodePacked(r, s, v));
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        offers.bid(t, bidder, 0, validBefore, signature);
    }

    /// While Circle pauses USDC, or blocklists a bidder, slots still move and records stay exact;
    /// only the paying step waits.
    function test_fork_usdc_pause_and_blocklist_never_jam_a_slot() public {
        bytes32 showing = _bid(SLOT, 100_000_000);
        bytes32 waiting = _bid(SLOT, 200_000_000);
        bytes32 other = _bid(keccak256("forum#2"), 50_000_000);
        vm.prank(operator);
        offers.place(showing);

        vm.prank(USDC.pauser());
        USDC.pause();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.startPrank(operator);
        offers.place(waiting); // replaces `showing`
        offers.returnBid(other);
        vm.stopPrank();
        vm.expectRevert(bytes("Pausable: paused"));
        offers.payOut(bidder);
        vm.prank(USDC.pauser());
        USDC.unpause();

        vm.prank(USDC.blacklister());
        USDC.blacklist(bidder);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(waiting);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        offers.payOut(bidder);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(USDC.balanceOf(address(offers)), offers.owed(bidder));

        vm.prank(USDC.blacklister());
        USDC.unBlacklist(bidder);
        offers.payOut(bidder);
        assertEq(USDC.balanceOf(address(offers)), 0);
        assertEq(offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(), 0);
    }

    /// The real token and the real staking contract are never payout wallets.
    function test_fork_usdc_and_staking_are_never_payout_wallets() public {
        vm.startPrank(admin);
        vm.expectRevert(RegentOffers.ContractIsParty.selector);
        offers.setPayout(VENUE, address(USDC));
        vm.expectRevert(RegentOffers.ContractIsParty.selector);
        offers.setPayout(VENUE, STAKING);
        vm.stopPrank();
    }

    /// The real staking contract takes a deposit of one base unit, from this contract, under this
    /// tag; and while it is paused only the push waits.
    function test_fork_real_staking_takes_dust_and_a_pause_holds_only_the_push() public {
        bytes32 first = _bid(SLOT, 1_000_000);
        bytes32 second = _bid(SLOT, 1_000_000);
        vm.prank(operator);
        offers.place(first);
        vm.warp(vm.getBlockTimestamp() + 3);
        vm.prank(operator);
        offers.place(second); // 3 s of 72 h on 1 USDC: 11 units paid, 1 unit of staking share
        assertEq(offers.revenueOwed(), 1);

        address stakingOwner = IRealStaking(STAKING).owner();
        vm.prank(stakingOwner);
        IRealStaking(STAKING).setPaused(true);
        vm.expectRevert(bytes("PAUSED"));
        offers.pushRevenue();
        offers.payOut(bidder);
        offers.payOut(payout);
        vm.prank(stakingOwner);
        IRealStaking(STAKING).setPaused(false);

        uint256 before = USDC.balanceOf(STAKING);
        vm.prank(stranger);
        offers.pushRevenue();
        assertEq(USDC.balanceOf(STAKING), before + 1);
        assertEq(USDC.allowance(address(offers), STAKING), 0);
        assertEq(USDC.balanceOf(address(offers)), offers.totalCommitted());
    }

    /// An account upgraded with EIP-7702 is checked through ERC-1271 by the real USDC. A signature
    /// made before the upgrade stops working if the delegate has no ERC-1271 answer (no money
    /// moves); with a delegate that accepts the account's own key the same signature funds the bid.
    /// forge-config: default.evm_version = "prague"
    function test_fork_an_eip7702_account_bids_only_through_its_delegates_erc1271() public {
        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        bytes memory signature = _sign(bidderKey, bidder, address(offers), t, validBefore);

        vm.etch(bidder, abi.encodePacked(hex"ef0100", address(new DelegateWithoutERC1271())));
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        offers.bid(t, bidder, 0, validBefore, signature);
        assertEq(USDC.balanceOf(bidder), 1_000_000_000);

        vm.etch(bidder, abi.encodePacked(hex"ef0100", address(new DelegateAcceptingOwnKey())));
        bytes32 id = offers.bid(t, bidder, 0, validBefore, signature);
        (address who,,,,,,,,) = offers.bids(id);
        assertEq(who, bidder);
        assertEq(USDC.balanceOf(bidder), 950_000_000);
    }
}

contract DelegateWithoutERC1271 {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

contract DelegateAcceptingOwnKey {
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == address(this) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
