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
///         public Base endpoint. Nothing is broadcast. Every bid is made the one way there is: the
///         bidder signs one USDC `ReceiveWithAuthorization` and the site submits it. That is shown
///         for a plain account, an account upgraded with EIP-7702 and a contract wallet, each
///         through to payment. The offline gate leaves this folder out; run it with
///         `make check-contracts-fork` from the repository root, or from this folder with
///         `forge test --match-path 'test/fork/*'`.
/// @dev Labels are unique on purpose: Foundry's plain names, such as "alice", are addresses that
///      are already delegated with EIP-7702 on Base, and real USDC then asks their delegate about
///      their signatures.
contract RegentOffersForkTest is Test {
    IRealUSDC internal constant USDC = IRealUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint32 internal constant LENGTH = 72 hours;
    uint256 internal constant WINDOW = 10 minutes;
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
    /// @dev Submits signed bids, as the venue's site does; it holds no role.
    address internal site = makeAddr("regent-offers-fork-site-1106");
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

    /// @dev The EIP-712 digest real USDC checks for `from`'s authorization of a bid on `t`.
    function _digest(address from, RegentOffers.Terms memory t, uint256 validBefore) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_TYPEHASH,
                from,
                address(offers),
                t.amount,
                uint256(0),
                validBefore,
                keccak256(abi.encode(address(offers), t))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev A plain 65-byte signature by `key` over the digest, r then s then v.
    function _sign(uint256 key, address from, RegentOffers.Terms memory t, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(from, t, validBefore));
        return abi.encodePacked(r, s, v);
    }

    /// @dev `key` signs for `from` and the site submits the bid.
    function _bidAs(uint256 key, address from, RegentOffers.Terms memory t) internal returns (bytes32) {
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        bytes memory signature = _sign(key, from, t, validBefore);
        vm.prank(site);
        return offers.bid(t, from, 0, validBefore, signature);
    }

    function _bid(bytes32 slot, uint96 amount) internal returns (bytes32) {
        return _bidAs(bidderKey, bidder, _terms(slot, amount));
    }

    function _status(bytes32 id) internal view returns (RegentOffers.Status s) {
        (,,,,,,,, s) = offers.bids(id);
    }

    function _bidder(bytes32 id) internal view returns (address who) {
        (who,,,,,,,,) = offers.bids(id);
    }

    /// @dev Nothing of a refused bid was recorded, moved or used up.
    function _nothingRecorded(address from, RegentOffers.Terms memory t, uint256 balanceBefore) internal view {
        assertEq(uint8(_status(offers.bidIdOf(from, t))), uint8(RegentOffers.Status.None));
        assertEq(offers.totalCommitted(), 0);
        assertEq(USDC.balanceOf(from), balanceBefore);
        assertFalse(USDC.authorizationState(from, offers.nonceOf(t)));
    }

    /// The placement runs its full length; the venue's 90% and staking's 10% are paid.
    function _placeFinishAndPay(bytes32 id, uint96 amount) internal {
        vm.prank(operator);
        offers.place(id);
        _finishAndPay(id, amount, 0);
    }

    /// Finishes a placement already showing and pays out, on top of `alreadyPaid` from before.
    function _finishAndPay(bytes32 id, uint96 amount, uint96 alreadyPaid) internal {
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

    // ------------------------------------------------------------ signatures

    /// The real USDC lets a bidder's signature do one thing only: fund its exact bid on this
    /// market, once, from anyone who submits it.
    function test_fork_a_signature_serves_only_its_own_bid() public {
        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, t, validBefore);
        bytes32 nonce = offers.nonceOf(t);
        assertEq(nonce, keccak256(abi.encode(address(offers), t)));
        uint256 balance = USDC.balanceOf(bidder);

        // A stranger cannot pull the money to the market without recording the bid, nor through
        // the transfer form of the same authorization.
        vm.startPrank(stranger);
        vm.expectRevert();
        USDC.receiveWithAuthorization(bidder, address(offers), t.amount, 0, validBefore, nonce, signature);
        vm.expectRevert();
        USDC.transferWithAuthorization(bidder, address(offers), t.amount, 0, validBefore, nonce, signature);
        vm.stopPrank();
        _nothingRecorded(bidder, t, balance);

        // Another market with the same venue cannot use it.
        RegentOffers twin = _market();
        vm.expectRevert();
        twin.bid(t, bidder, 0, validBefore, signature);
        assertEq(twin.totalCommitted(), 0);

        // Changed terms, payer or time window are refused. A memory struct assignment is a
        // reference, so each change is undone before the next.
        t.amount += 1;
        vm.expectRevert();
        offers.bid(t, bidder, 0, validBefore, signature);
        t.amount -= 1;
        t.placeBy += 1;
        vm.expectRevert();
        offers.bid(t, bidder, 0, validBefore, signature);
        t.placeBy -= 1;
        t.lane = 1;
        vm.expectRevert();
        offers.bid(t, bidder, 0, validBefore, signature);
        t.lane = 0;
        t.wordingHash = keccak256("other wording");
        vm.expectRevert();
        offers.bid(t, bidder, 0, validBefore, signature);
        t.wordingHash = keccak256("wording");
        assertEq(offers.nonceOf(t), nonce);
        vm.expectRevert();
        offers.bid(t, stranger, 0, validBefore, signature);
        vm.expectRevert();
        offers.bid(t, bidder, 0, validBefore + 1, signature);
        // The zero address and the market itself are never bidders.
        vm.expectRevert();
        offers.bid(t, address(0), 0, validBefore, signature);
        vm.expectRevert();
        offers.bid(t, address(offers), 0, validBefore, signature);
        _nothingRecorded(bidder, t, balance);

        // The exact bid goes through once, from anyone, with the bidder's money.
        vm.prank(stranger);
        bytes32 id = offers.bid(t, bidder, 0, validBefore, signature);
        assertEq(_bidder(id), bidder);
        assertEq(USDC.balanceOf(bidder), balance - 50_000_000);
        assertTrue(USDC.authorizationState(bidder, nonce));
        vm.expectRevert(RegentOffers.BidExists.selector);
        vm.prank(site);
        offers.bid(t, bidder, 0, validBefore, signature);

        // Once the window has closed, a signature never submitted funds nothing.
        RegentOffers.Terms memory late = _terms(SLOT, 1_000_000);
        bytes memory lateSignature = _sign(bidderKey, bidder, late, validBefore);
        vm.warp(validBefore);
        vm.expectRevert();
        vm.prank(site);
        offers.bid(late, bidder, 0, validBefore, lateSignature);
        assertEq(uint8(_status(offers.bidIdOf(bidder, late))), uint8(RegentOffers.Status.None));
        assertEq(offers.totalCommitted(), 50_000_000);
    }

    /// A bidder can kill a signature before anyone submits it.
    function test_fork_a_bidder_can_cancel_an_unsubmitted_signature() public {
        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, t, validBefore);
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
        assertTrue(USDC.authorizationState(bidder, nonce));
        uint256 balance = USDC.balanceOf(bidder);
        vm.expectRevert();
        vm.prank(site);
        offers.bid(t, bidder, 0, validBefore, signature);
        assertEq(uint8(_status(offers.bidIdOf(bidder, t))), uint8(RegentOffers.Status.None));
        assertEq(offers.totalCommitted(), 0);
        assertEq(USDC.balanceOf(bidder), balance);
    }

    // ------------------------------------------------------- three bidders

    /// A plain account with no code signs; its bid is placed, runs its length and is paid.
    function test_fork_a_plain_account_signs_a_bid() public {
        (address eoa, uint256 key) = makeAddrAndKey("regent-offers-fork-plain-1106");
        assertEq(eoa.code.length, 0);
        deal(address(USDC), eoa, 50_000_000);

        bytes32 id = _bidAs(key, eoa, _terms(SLOT, 50_000_000));
        assertEq(_bidder(id), eoa);
        assertEq(USDC.balanceOf(eoa), 0);
        assertEq(USDC.balanceOf(site), 0);
        _placeFinishAndPay(id, 50_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    /// An account upgraded with EIP-7702 has code, so real USDC asks its delegate through ERC-1271
    /// instead of checking the key itself. The delegate here accepts a plain 65-byte signature
    /// (r, s, v) made by the account's own key over the exact EIP-712 digest USDC passes it, with
    /// no wrapping and no prefix. Under a delegate with no ERC-1271 answer the same kind of
    /// signature is refused and no money moves. The first bid is replaced an hour in by a second,
    /// and its unused time is paid back to the upgraded account.
    /// forge-config: default.evm_version = "prague"
    function test_fork_an_eip7702_account_signs_through_its_delegates_erc1271() public {
        (address eoa, uint256 key) = makeAddrAndKey("regent-offers-fork-7702-1106");
        assertEq(eoa.code.length, 0);
        deal(address(USDC), eoa, 300_000_000);

        DelegateWithoutERC1271 silent = new DelegateWithoutERC1271();
        vm.signAndAttachDelegation(address(silent), key);
        DelegateWithoutERC1271(eoa).ping();
        assertEq(keccak256(eoa.code), keccak256(abi.encodePacked(hex"ef0100", address(silent))));
        RegentOffers.Terms memory refusedTerms = _terms(SLOT, 72_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        bytes memory refusedSignature = _sign(key, eoa, refusedTerms, validBefore);
        vm.expectRevert();
        vm.prank(site);
        offers.bid(refusedTerms, eoa, 0, validBefore, refusedSignature);
        _nothingRecorded(eoa, refusedTerms, 300_000_000);

        DelegateAcceptingOwnKey delegate = new DelegateAcceptingOwnKey();
        vm.signAndAttachDelegation(address(delegate), key);
        DelegateAcceptingOwnKey(eoa).ping();
        assertEq(keccak256(eoa.code), keccak256(abi.encodePacked(hex"ef0100", address(delegate))));

        bytes32 first = _bidAs(key, eoa, _terms(SLOT, 72_000_000));
        assertEq(_bidder(first), eoa);
        assertEq(USDC.balanceOf(eoa), 228_000_000);
        vm.prank(operator);
        offers.place(first);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        bytes32 second = _bidAs(key, eoa, _terms(SLOT, 144_000_000));
        assertEq(USDC.balanceOf(eoa), 84_000_000);
        vm.prank(operator);
        offers.place(second); // one hour of 72 shown: 1 USDC paid, 71 owed back
        assertEq(offers.owed(eoa), 71_000_000);
        offers.payOut(eoa);
        assertEq(USDC.balanceOf(eoa), 155_000_000);

        _finishAndPay(second, 144_000_000, 1_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    /// A contract wallet signs through ERC-1271 with its owner's key; one bid is placed and paid,
    /// another is handed back and paid out to the wallet. A key that is not its owner's is refused.
    function test_fork_a_contract_wallet_signs_through_erc1271() public {
        (address walletOwner, uint256 ownerKey) = makeAddrAndKey("regent-offers-fork-wallet-owner-1106");
        SmartWallet wallet = new SmartWallet(walletOwner);
        deal(address(USDC), address(wallet), 80_000_000);

        RegentOffers.Terms memory t = _terms(SLOT, 50_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        bytes memory notTheOwner = _sign(bidderKey, address(wallet), t, validBefore);
        vm.expectRevert();
        vm.prank(site);
        offers.bid(t, address(wallet), 0, validBefore, notTheOwner);
        _nothingRecorded(address(wallet), t, 80_000_000);

        bytes32 shown = _bidAs(ownerKey, address(wallet), t);
        bytes32 back = _bidAs(ownerKey, address(wallet), _terms(keccak256("forum#2"), 30_000_000));
        assertEq(_bidder(shown), address(wallet));
        assertEq(_bidder(back), address(wallet));
        assertEq(USDC.balanceOf(address(wallet)), 0);

        vm.prank(operator);
        offers.returnBid(back);
        offers.payOut(address(wallet));
        assertEq(USDC.balanceOf(address(wallet)), 30_000_000);
        _placeFinishAndPay(shown, 50_000_000);
        assertEq(USDC.balanceOf(address(offers)), 0);
    }

    // --------------------------------------------------- the real token's rules

    /// While Circle pauses USDC, or blocklists a bidder, slots still move and records stay exact;
    /// only the paying step waits. While paused, a new bid cannot be funded.
    function test_fork_usdc_pause_and_blocklist_never_jam_a_slot() public {
        bytes32 showing = _bid(SLOT, 100_000_000);
        bytes32 waiting = _bid(SLOT, 200_000_000);
        bytes32 other = _bid(keccak256("forum#2"), 50_000_000);
        vm.prank(operator);
        offers.place(showing);

        RegentOffers.Terms memory t = _terms(keccak256("forum#3"), 1_000_000);
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sign(bidderKey, bidder, t, validBefore);

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
        uint256 committed = offers.totalCommitted();
        vm.expectRevert();
        vm.prank(site);
        offers.bid(t, bidder, 0, validBefore, signature);
        assertEq(offers.totalCommitted(), committed, "a bid USDC refused records nothing");
        assertEq(uint8(_status(offers.bidIdOf(bidder, t))), uint8(RegentOffers.Status.None));
        assertFalse(USDC.authorizationState(bidder, offers.nonceOf(t)), "the signature stays unused");
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

/// @notice An EIP-7702 delegate with no ERC-1271 answer.
contract DelegateWithoutERC1271 {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice An EIP-7702 delegate whose ERC-1271 answer accepts a plain 65-byte signature by the
///         account's own key over the digest it is given.
contract DelegateAcceptingOwnKey {
    function ping() external pure returns (uint256) {
        return 1;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == address(this) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice A minimal contract wallet: its ERC-1271 answer accepts its owner key's plain 65-byte
///         signature over the digest it is given.
contract SmartWallet {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        return err == ECDSA.RecoverError.NoError && signer == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
