// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegentOffers, IRegentRevenueStaking} from "../../src/RegentOffers.sol";

interface IRealUSDC is IERC20 {
    function pauser() external view returns (address);
    function blacklister() external view returns (address);
    function pause() external;
    function unpause() external;
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

interface IRealStaking {
    function owner() external view returns (address);
    function setPaused(bool paused) external;
}

/// @title RegentOffersForkTest
/// @notice Against the real Base USDC and the real REGENT staking contract on a local fork of the
///         public Base endpoint. Nothing is broadcast. Every bid is made the one way there is: the
///         bidder's own account approves this contract, then calls `bid`; that is shown for a plain
///         account, an account upgraded with EIP-7702 and a contract account, each through to
///         payment. The offline gate leaves this folder out; run it with `make check-contracts-fork`
///         from the repository root, or from this folder with `forge test --match-path 'test/fork/*'`.
/// @dev Labels are unique on purpose: Foundry's plain names, such as "alice", are addresses that
///      are already delegated with EIP-7702 on Base.
contract RegentOffersForkTest is Test {
    IRealUSDC internal constant USDC = IRealUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint32 internal constant LENGTH = 72 hours;

    RegentOffers internal offers;
    address internal owner = makeAddr("regent-offers-fork-owner-1106");
    address internal admin = makeAddr("regent-offers-fork-admin-1106");
    address internal operator = makeAddr("regent-offers-fork-operator-1106");
    address internal moderator = makeAddr("regent-offers-fork-moderator-1106");
    address internal payout = makeAddr("regent-offers-fork-payout-1106");
    address internal stranger = makeAddr("regent-offers-fork-stranger-1106");
    address internal bidder = makeAddr("regent-offers-fork-bidder-1106");
    uint256 internal salts;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        offers = new RegentOffers(USDC, IRegentRevenueStaking(STAKING), 1000, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, 1_000_000, LENGTH);
        deal(address(USDC), bidder, 1_000_000_000);
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

    /// @dev `from` approves, then bids, as two calls from its own account.
    function _bidAs(address from, RegentOffers.Terms memory t) internal returns (bytes32 id) {
        vm.startPrank(from);
        USDC.approve(address(offers), t.amount);
        id = offers.bid(t);
        vm.stopPrank();
    }

    function _bid(bytes32 slot, uint96 amount) internal returns (bytes32) {
        return _bidAs(bidder, _terms(slot, amount));
    }

    function _status(bytes32 id) internal view returns (RegentOffers.Status s) {
        (,,,,,,,, s) = offers.bids(id);
    }

    function _bidder(bytes32 id) internal view returns (address who) {
        (who,,,,,,,,) = offers.bids(id);
    }

    /// The placement runs its full length; the venue's 90% and staking's 10% are paid.
    function _placeFinishAndPay(bytes32 id, uint96 amount) internal {
        vm.prank(operator);
        offers.place(id);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        uint256 venueBefore = USDC.balanceOf(payout);
        uint256 stakingBefore = USDC.balanceOf(STAKING);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(USDC.balanceOf(payout), venueBefore + uint256(amount) * 9 / 10);
        assertEq(USDC.balanceOf(STAKING), stakingBefore + uint256(amount) / 10);
    }

    /// A plain account approves, then bids; the bid is placed, runs its length and is paid.
    function test_fork_a_plain_account_approves_then_bids() public {
        address eoa = makeAddr("regent-offers-fork-plain-1106");
        assertEq(eoa.code.length, 0);
        deal(address(USDC), eoa, 50_000_000);

        bytes32 id = _bidAs(eoa, _terms(SLOT, 50_000_000));
        assertEq(_bidder(id), eoa);
        assertEq(USDC.balanceOf(eoa), 0);
        assertEq(USDC.allowance(eoa, address(offers)), 0);
        _placeFinishAndPay(id, 50_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    /// An account upgraded with EIP-7702 to a batch delegate approves and bids in one call to
    /// itself, and the same account can also do it as two plain calls. The first bid is replaced
    /// by the second an hour in, so its unused time is paid back to the upgraded account.
    /// forge-config: default.evm_version = "prague"
    function test_fork_an_eip7702_account_bids_in_one_call_or_in_two() public {
        (address eoa, uint256 key) = makeAddrAndKey("regent-offers-fork-7702-1106");
        assertEq(eoa.code.length, 0);
        deal(address(USDC), eoa, 300_000_000);
        BatchExecutor batch = new BatchExecutor();

        RegentOffers.Terms memory t = _terms(SLOT, 72_000_000);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(address(USDC), abi.encodeCall(IERC20.approve, (address(offers), t.amount)));
        calls[1] = BatchExecutor.Call(address(offers), abi.encodeCall(RegentOffers.bid, (t)));
        vm.signAndAttachDelegation(address(batch), key);
        vm.prank(eoa);
        bytes[] memory answers = BatchExecutor(eoa).execute(calls);
        assertEq(keccak256(eoa.code), keccak256(abi.encodePacked(hex"ef0100", address(batch))));
        bytes32 first = abi.decode(answers[1], (bytes32));
        assertEq(_bidder(first), eoa);
        assertEq(USDC.balanceOf(eoa), 228_000_000);

        // Only the account itself may have its delegate make calls.
        vm.prank(stranger);
        vm.expectRevert(BatchExecutor.NotSelf.selector);
        BatchExecutor(eoa).execute(calls);

        vm.prank(operator);
        offers.place(first);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        bytes32 second = _bidAs(eoa, _terms(SLOT, 144_000_000));
        assertEq(_bidder(second), eoa);
        assertEq(USDC.balanceOf(eoa), 84_000_000);
        vm.prank(operator);
        offers.place(second); // one hour of 72 shown: 1 USDC paid, 71 owed back
        assertEq(offers.owed(eoa), 71_000_000);
        offers.payOut(eoa);
        assertEq(USDC.balanceOf(eoa), 155_000_000);

        _placeFinishAndPayLive(second, 144_000_000, 1_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    /// A contract account, run by its owner, approves and bids from itself; one bid is placed and
    /// paid, another is handed back and paid out to the contract account.
    function test_fork_a_contract_account_approves_then_bids() public {
        address accountOwner = makeAddr("regent-offers-fork-account-owner-1106");
        SmartAccount account = new SmartAccount(accountOwner);
        deal(address(USDC), address(account), 80_000_000);

        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        RegentOffers.Terms memory u = _terms(keccak256("forum#2"), 30_000_000);
        vm.startPrank(accountOwner);
        account.execute(address(USDC), abi.encodeCall(IERC20.approve, (address(offers), 80_000_000)));
        bytes32 shown = abi.decode(account.execute(address(offers), abi.encodeCall(RegentOffers.bid, (t))), (bytes32));
        bytes32 back = abi.decode(account.execute(address(offers), abi.encodeCall(RegentOffers.bid, (u))), (bytes32));
        vm.stopPrank();
        assertEq(_bidder(shown), address(account));
        assertEq(_bidder(back), address(account));
        assertEq(USDC.balanceOf(address(account)), 0);

        vm.expectRevert(SmartAccount.NotOwner.selector);
        vm.prank(stranger);
        account.execute(address(offers), abi.encodeCall(RegentOffers.bid, (t)));

        vm.prank(operator);
        offers.returnBid(back);
        offers.payOut(address(account));
        assertEq(USDC.balanceOf(address(account)), 30_000_000);
        _placeFinishAndPay(shown, 50_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    /// Finishes a placement already showing and pays out, on top of `alreadyPaid` from before.
    function _placeFinishAndPayLive(bytes32 id, uint96 amount, uint96 alreadyPaid) internal {
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        uint256 venueBefore = USDC.balanceOf(payout);
        uint256 stakingBefore = USDC.balanceOf(STAKING);
        offers.payOut(payout);
        offers.pushRevenue();
        uint256 paid = uint256(amount) + alreadyPaid;
        assertEq(USDC.balanceOf(payout), venueBefore + paid * 9 / 10);
        assertEq(USDC.balanceOf(STAKING), stakingBefore + paid / 10);
    }

    /// While Circle pauses USDC, or blocklists a bidder, slots still move and records stay exact;
    /// only the paying step waits. While paused, a new bid cannot be funded.
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
        uint256 owedBack = offers.owed(bidder);
        assertGt(owedBack, 0);
        vm.expectRevert();
        offers.payOut(bidder);
        assertEq(offers.owed(bidder), owedBack, "a payment USDC refused leaves the debt as it was");
        RegentOffers.Terms memory t = _terms(keccak256("forum#3"), 1_000_000);
        uint256 committed = offers.totalCommitted();
        vm.expectRevert();
        vm.prank(bidder);
        offers.bid(t);
        assertEq(offers.totalCommitted(), committed, "a bid USDC refused records nothing");
        assertEq(uint8(_status(offers.bidIdOf(bidder, t))), uint8(RegentOffers.Status.None));
        vm.prank(USDC.pauser());
        USDC.unpause();

        vm.prank(USDC.blacklister());
        USDC.blacklist(bidder);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(waiting);
        owedBack = offers.owed(bidder);
        vm.expectRevert();
        offers.payOut(bidder);
        assertEq(offers.owed(bidder), owedBack, "a blocked bidder's money stays owed to it");
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
        vm.startPrank(owner);
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
        vm.expectRevert();
        offers.pushRevenue();
        assertEq(offers.revenueOwed(), 1, "a refused push leaves the share owed");
        assertEq(USDC.allowance(address(offers), STAKING), 0);
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
}

/// @notice A minimal EIP-7702 delegate: the account it is set on can make several calls in one.
contract BatchExecutor {
    struct Call {
        address to;
        bytes data;
    }

    error NotSelf();

    function execute(Call[] calldata calls) external returns (bytes[] memory answers) {
        if (msg.sender != address(this)) revert NotSelf();
        answers = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            answers[i] = _call(calls[i].to, calls[i].data);
        }
    }

    function _call(address to, bytes calldata data) private returns (bytes memory answer) {
        bool ok;
        (ok, answer) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }
}

/// @notice A minimal contract account: its owner has it call anything.
contract SmartAccount {
    address internal immutable owner;

    error NotOwner();

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address to, bytes calldata data) external returns (bytes memory answer) {
        if (msg.sender != owner) revert NotOwner();
        bool ok;
        (ok, answer) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }
}
