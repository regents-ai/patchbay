// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegentOffers, IRegentRevenueStaking} from "../../src/RegentOffers.sol";
import {Review3Entry, R3USDC, R3Wallet} from "./Review3Base.sol";
import {R3ReenteringWallet} from "./Review3Signed.t.sol";
import {R3MoodyWallet, R3SilentDelegate} from "./Review3SignedFindings.t.sol";

interface IR3RealUSDC {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

/// @notice Review 3 against the real Base USDC and the real REGENT staking contract, on a local
///         fork read through the RPC address already in the shell environment
///         (REGENT_BASE_RPC_URL). Nothing is broadcast and no real key is used. Run with
///         `forge test --match-path test/review3/Review3Fork.t.sol`.
/// @dev Names are unique on purpose so the test accounts have no code on Base.
contract Review3ForkTest is Review3Entry {
    address internal constant REAL_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant REAL_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint32 internal constant LENGTH = 72 hours;
    uint96 internal constant AMOUNT = 72_000_000;
    uint256 internal constant WINDOW = 10 minutes;

    address internal owner;
    address internal admin;
    address internal operator;
    address internal moderator;
    address internal payout;
    address internal bidder;
    address internal bidder2;
    address internal stranger;

    function setUp() public {
        vm.createSelectFork(vm.envString("REGENT_BASE_RPC_URL"));
        assertEq(block.chainid, 8453, "not Base");
        usdc = R3USDC(REAL_USDC);
        owner = makeAddr("review3-fork-owner-ad0a2cff");
        admin = makeAddr("review3-fork-admin-ad0a2cff");
        operator = makeAddr("review3-fork-operator-ad0a2cff");
        moderator = makeAddr("review3-fork-moderator-ad0a2cff");
        payout = makeAddr("review3-fork-payout-ad0a2cff");
        bidder = makeAddr("review3-fork-bidder-ad0a2cff");
        bidder2 = makeAddr("review3-fork-bidder2-ad0a2cff");
        stranger = makeAddr("review3-fork-stranger-ad0a2cff");
        relayer = makeAddr("review3-fork-relayer-ad0a2cff");
        assertEq(bidder.code.length + bidder2.code.length + payout.code.length, 0, "test accounts must be plain");
        offers = _market();
    }

    function _market() internal returns (RegentOffers o) {
        o = new RegentOffers(usdc, IRegentRevenueStaking(REAL_STAKING), 1000, owner);
        vm.prank(owner);
        o.addVenue(VENUE, admin, operator, moderator, payout, 1_000_000, LENGTH);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _fresh(bytes32 slot, uint96 amount) internal returns (RegentOffers.Terms memory) {
        return _terms(VENUE, slot, amount, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
    }

    /// @dev `from` has `amount` more, signs with its known key and the relayer submits.
    function _bid(address from, bytes32 slot, uint96 amount) internal returns (bytes32 id) {
        RegentOffers.Terms memory t = _fresh(slot, amount);
        deal(address(usdc), from, usdc.balanceOf(from) + amount);
        uint256 validBefore = _now() + WINDOW;
        bool ok;
        (ok, id,) = _submit(relayer, t, from, 0, validBefore, _signBid(keyOf[from], from, address(offers), t, 0, validBefore));
        require(ok, "bid refused");
    }

    function _status(bytes32 id) internal view returns (RegentOffers.Status) {
        return _rec(id).status;
    }

    /// @notice HELD on real USDC. Only the market can use the signature; nobody can spend it
    ///         elsewhere or burn it; it buys the signed bid once and no altered bid.
    function test_R3_K1_real_usdc_lets_only_the_market_use_the_signature() public {
        RegentOffers twin = _market();
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        bytes32 nonce = offers.nonceOf(t);
        deal(address(usdc), bidder, 10 * uint256(AMOUNT));

        vm.startPrank(stranger);
        vm.expectRevert();
        usdc.receiveWithAuthorization(bidder, address(offers), AMOUNT, 0, validBefore, nonce, signature);
        vm.expectRevert();
        usdc.receiveWithAuthorization(bidder, stranger, AMOUNT, 0, validBefore, nonce, signature);
        vm.expectRevert();
        usdc.transferWithAuthorization(bidder, address(offers), AMOUNT, 0, validBefore, nonce, signature);
        vm.expectRevert();
        usdc.transferWithAuthorization(bidder, stranger, AMOUNT, 0, validBefore, nonce, signature);
        vm.expectRevert();
        usdc.cancelAuthorization(bidder, nonce, signature);
        vm.stopPrank();
        assertFalse(usdc.authorizationState(bidder, nonce), "the nonce is still unused");

        // The twin market, and each altered term.
        vm.prank(relayer);
        (bool ok,) = address(twin).call(abi.encodeCall(RegentOffers.bid, (t, bidder, 0, validBefore, signature)));
        assertFalse(ok, "another market took it");
        RegentOffers.Terms memory x = _alter(t);
        x.amount += 1;
        _refused(x, bidder, 0, validBefore, signature);
        x = _alter(t);
        x.slot = keccak256("forum#2");
        _refused(x, bidder, 0, validBefore, signature);
        x = _alter(t);
        x.wordingHash = keccak256("other wording");
        _refused(x, bidder, 0, validBefore, signature);
        x = _alter(t);
        x.placeBy += 1;
        _refused(x, bidder, 0, validBefore, signature);
        x = _alter(t);
        x.salt = bytes32(uint256(12345));
        _refused(x, bidder, 0, validBefore, signature);
        _refused(t, bidder2, 0, validBefore, signature);
        _refused(t, bidder, 0, validBefore + 1, signature);
        _refused(t, bidder, 1, validBefore, signature);
        assertEq(usdc.balanceOf(bidder), 10 * uint256(AMOUNT), "nothing moved");
        assertEq(usdc.balanceOf(address(offers)) + usdc.balanceOf(address(twin)), 0);

        bytes32 id;
        (ok, id,) = _submit(stranger, t, bidder, 0, validBefore, signature);
        assertTrue(ok, "the bid as signed is taken, whoever sends it");
        assertEq(_rec(id).bidder, bidder);
        assertTrue(usdc.authorizationState(bidder, nonce));
        bytes memory why;
        (ok,, why) = _submit(relayer, t, bidder, 0, validBefore, signature);
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.BidExists.selector);
        assertEq(usdc.balanceOf(bidder), 9 * uint256(AMOUNT), "charged once");
    }

    function _alter(RegentOffers.Terms memory t) internal pure returns (RegentOffers.Terms memory) {
        return abi.decode(abi.encode(t), (RegentOffers.Terms));
    }

    function _refused(RegentOffers.Terms memory t, address from, uint256 validAfter, uint256 validBefore, bytes memory signature)
        internal
    {
        (bool ok,,) = _submit(relayer, t, from, validAfter, validBefore, signature);
        assertFalse(ok, "an altered bid was taken");
        assertEq(uint8(_status(offers.bidIdOf(from, t))), uint8(RegentOffers.Status.None));
    }

    /// @notice HELD on real USDC. Reshaped copies of a good signature are all refused: the twin with
    ///         the other `s`, the 64-byte short form, a padded one, and odd `v` values.
    function test_R3_K2_real_usdc_refuses_reshaped_signatures() public {
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        deal(address(usdc), bidder, AMOUNT);
        bytes32 digest =
            _digest(address(usdc), RECEIVE_TYPEHASH, bidder, address(offers), AMOUNT, 0, validBefore, offers.nonceOf(t));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[bidder], digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 otherS = bytes32(n - uint256(s));
        uint8 otherV = v == 27 ? 28 : 27;
        assertEq(ecrecover(digest, otherV, r, otherS), bidder, "the twin is a real signature by the same key");

        bytes[6] memory shapes = [
            abi.encodePacked(r, otherS, otherV),
            abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255))),
            abi.encodePacked(r, s, v, uint8(0)),
            abi.encodePacked(r, s, uint8(v - 27)),
            abi.encodePacked(r, s),
            bytes("")
        ];
        for (uint256 i; i < shapes.length; ++i) {
            (bool ok,,) = _submit(relayer, t, bidder, 0, validBefore, shapes[i]);
            assertFalse(ok, "a reshaped signature was taken");
        }
        assertEq(usdc.balanceOf(bidder), AMOUNT);
        (bool good,,) = _submit(relayer, t, bidder, 0, validBefore, abi.encodePacked(r, s, v));
        assertTrue(good);
    }

    /// @notice HELD on real USDC. A contract wallet is asked read-only: one that tries to act on the
    ///         half-made bid gets nothing through, and one that tries to write is refused.
    function test_R3_K3_real_usdc_asks_contract_wallets_read_only() public {
        R3ReenteringWallet wallet = new R3ReenteringWallet(offers);
        vm.prank(admin);
        offers.setOperator(VENUE, address(wallet));
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        deal(address(usdc), address(wallet), AMOUNT);
        wallet.aim(offers.bidIdOf(address(wallet), t));
        (bool ok, bytes32 id,) = _submit(relayer, t, address(wallet), 0, _now() + WINDOW, "");
        assertTrue(ok, "the wallet got a call through, or did not see the bid");
        assertEq(uint8(_status(id)), uint8(RegentOffers.Status.Held));
        assertEq(offers.live(VENUE, SLOT), bytes32(0));
        assertEq(usdc.balanceOf(address(offers)), AMOUNT);

        R3WritingWallet writer = new R3WritingWallet();
        deal(address(usdc), address(writer), AMOUNT);
        t = _fresh(SLOT, AMOUNT);
        (ok,,) = _submit(relayer, t, address(writer), 0, _now() + WINDOW, "");
        assertFalse(ok, "a wallet that writes while being asked is refused");
        assertEq(writer.asked(), 0);

        // An ordinary contract wallet, signed for by its owner's key, bids and is refunded.
        R3Wallet honest = new R3Wallet(bidder);
        deal(address(usdc), address(honest), AMOUNT);
        t = _fresh(keccak256("forum#2"), AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder], address(honest), address(offers), t, 0, validBefore);
        (ok, id,) = _submit(relayer, t, address(honest), 0, validBefore, signature);
        assertTrue(ok);
        // The same key's signature naming the key's own account is not the wallet's.
        RegentOffers.Terms memory t2 = _fresh(keccak256("forum#2"), AMOUNT);
        deal(address(usdc), address(honest), AMOUNT);
        signature = _signBid(keyOf[bidder], bidder, address(offers), t2, 0, validBefore);
        (ok,,) = _submit(relayer, t2, address(honest), 0, validBefore, signature);
        assertFalse(ok, "a signature naming another account moved the wallet's money");
        vm.warp(t.placeBy);
        offers.withdraw(id);
        offers.payOut(address(honest));
        assertEq(usdc.balanceOf(address(honest)), 2 * uint256(AMOUNT));
    }

    /// @notice F13 on real USDC, with a real EIP-7702 upgrade. A plain account signs a bid; it then
    ///         upgrades to code with no signature answer and the same signature is refused; it
    ///         removes the upgrade and the same signature works.
    /// forge-config: default.evm_version = "prague"
    function test_R3_K4_an_upgraded_account_with_no_signature_answer_cannot_bid() public {
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        deal(address(usdc), bidder, AMOUNT);

        R3SilentDelegate silent = new R3SilentDelegate();
        vm.signAndAttachDelegation(address(silent), keyOf[bidder]);
        vm.prank(stranger);
        (bool poke,) = bidder.call("");
        assertTrue(poke);
        assertEq(bidder.code.length, 23, "the account is upgraded");
        (bool ok,,) = _submit(relayer, t, bidder, 0, validBefore, signature);
        assertFalse(ok, "real USDC refuses the account's own correct signature");
        assertEq(usdc.balanceOf(bidder), AMOUNT);
        assertEq(uint8(_status(offers.bidIdOf(bidder, t))), uint8(RegentOffers.Status.None));

        vm.signAndAttachDelegation(address(0), keyOf[bidder]);
        vm.prank(stranger);
        (poke,) = bidder.call("");
        assertEq(bidder.code.length, 0, "the upgrade is removed");
        (ok,,) = _submit(relayer, t, bidder, 0, validBefore, signature);
        assertTrue(ok, "the same signature works again");
    }

    /// @notice F14 on real USDC. A hostile wallet says yes when checked and no when sent, and burns
    ///         nearly all the gas the sender allowed.
    function test_R3_K5_a_hostile_wallet_makes_the_sender_pay_for_nothing() public {
        R3MoodyWallet wallet = new R3MoodyWallet();
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        deal(address(usdc), address(wallet), AMOUNT);
        bytes memory data = abi.encodeCall(RegentOffers.bid, (t, address(wallet), 0, _now() + WINDOW, ""));
        wallet.set(true);
        uint256 snap = vm.snapshotState();
        vm.prank(relayer);
        (bool ok,) = address(offers).call(data);
        assertTrue(ok, "the check before sending says the bid will be taken");
        vm.revertToState(snap);
        wallet.set(false);
        uint256 allowed = 2_000_000;
        vm.prank(relayer);
        uint256 before = gasleft();
        (ok,) = address(offers).call{gas: allowed}(data);
        uint256 used = before - gasleft();
        assertFalse(ok);
        assertGt(used, (allowed * 95) / 100, "more than 95% of the allowed gas is burnt");
        assertEq(usdc.balanceOf(address(wallet)), AMOUNT);
    }

    /// @notice F16 and F18 on real USDC, as fixed in round 5: equal terms on a second market are
    ///         their own bid, and money the transfer form strands is sent back by the owner.
    function test_R3_K6_second_market_and_transfer_form_on_real_usdc() public {
        RegentOffers second = _market();
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        deal(address(usdc), bidder, 3 * uint256(AMOUNT));
        bytes memory forFirst = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        bytes memory forSecond = _signBid(keyOf[bidder], bidder, address(second), t, 0, validBefore);
        vm.prank(stranger);
        offers.bid(t, bidder, 0, validBefore, forFirst);
        vm.prank(relayer);
        second.bid(t, bidder, 0, validBefore, forSecond);
        assertEq(usdc.balanceOf(address(second)), AMOUNT, "the same terms on the second market are their own bid");

        RegentOffers.Terms memory t2 = _fresh(SLOT, AMOUNT);
        bytes32 nonce = second.nonceOf(t2);
        bytes memory transferForm = _sig(
            keyOf[bidder], _digest(address(usdc), TRANSFER_TYPEHASH, bidder, address(second), AMOUNT, 0, validBefore, nonce)
        );
        vm.prank(stranger);
        usdc.transferWithAuthorization(bidder, address(second), AMOUNT, 0, validBefore, nonce, transferForm);
        assertEq(usdc.balanceOf(address(second)), 2 * uint256(AMOUNT), "the money is in the market");
        assertEq(second.totalCommitted(), AMOUNT, "only the real bid is in the record");
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        second.payOut(bidder);
        vm.prank(owner);
        assertEq(second.recoverSurplus(bidder), AMOUNT, "the owner sends back only the stranded money");
        assertEq(usdc.balanceOf(address(second)), AMOUNT);
    }

    /// @notice HELD on real USDC and real staking. Three bids through every ending; a bidder blocked
    ///         by USDC cannot bid and leaves nothing behind; a blocked payout wallet waits while
    ///         everyone else is paid; at the end every unit taken in has gone out.
    function test_R3_K7_a_full_round_on_real_usdc_and_staking_adds_up() public {
        address blacklister = IR3RealUSDC(REAL_USDC).blacklister();
        uint256 stakingBefore = usdc.balanceOf(REAL_STAKING);

        // A blocked bidder.
        RegentOffers.Terms memory t = _fresh(SLOT, AMOUNT);
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder2], bidder2, address(offers), t, 0, validBefore);
        deal(address(usdc), bidder2, AMOUNT);
        vm.prank(blacklister);
        IR3RealUSDC(REAL_USDC).blacklist(bidder2);
        (bool ok,,) = _submit(relayer, t, bidder2, 0, validBefore, signature);
        assertFalse(ok, "a blocked bidder's bid was taken");
        assertEq(offers.totalCommitted(), 0);
        vm.prank(blacklister);
        IR3RealUSDC(REAL_USDC).unBlacklist(bidder2);
        deal(address(usdc), bidder2, 0);

        bytes32 a = _bid(bidder, SLOT, 100_000_001);
        bytes32 b = _bid(bidder2, SLOT, 40_000_003);
        bytes32 c = _bid(bidder, keccak256("forum#2"), 7_000_007);
        bytes32 d = _bid(bidder2, keccak256("forum#3"), 5_000_000);
        bytes32 e = _bid(bidder2, keccak256("forum#3"), 6_000_000);
        uint256 taken = 100_000_001 + 40_000_003 + 7_000_007 + 5_000_000 + 6_000_000;
        assertEq(usdc.balanceOf(address(offers)), taken);

        vm.startPrank(operator);
        offers.place(a);
        offers.place(c);
        offers.returnBid(d);
        vm.stopPrank();
        vm.warp(_now() + 1234);
        vm.prank(operator);
        offers.place(b); // replaces a after 1234 seconds
        vm.prank(moderator);
        offers.remove(c);
        vm.warp(_now() + LENGTH);
        offers.finish(b);
        offers.withdraw(e);
        assertEq(offers.totalCommitted(), 0);
        assertEq(usdc.balanceOf(address(offers)), offers.totalOwed() + offers.revenueOwed());

        // The payout wallet is blocked: it waits, the others are paid.
        vm.prank(blacklister);
        IR3RealUSDC(REAL_USDC).blacklist(payout);
        vm.expectRevert();
        offers.payOut(payout);
        offers.payOut(bidder);
        offers.payOut(bidder2);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(offers)), offers.owed(payout), "only the blocked wallet's money is left");
        vm.prank(blacklister);
        IR3RealUSDC(REAL_USDC).unBlacklist(payout);
        offers.payOut(payout);

        assertEq(usdc.balanceOf(address(offers)), 0, "nothing is left in the market");
        uint256 toStaking = usdc.balanceOf(REAL_STAKING) - stakingBefore;
        assertEq(
            usdc.balanceOf(bidder) + usdc.balanceOf(bidder2) + usdc.balanceOf(payout) + toStaking,
            taken,
            "every unit taken in went to a bidder, the venue or staking"
        );
        // a showed 1234 of 259200 seconds.
        uint256 paidA = (uint256(100_000_001) * 1234) / LENGTH;
        uint256 paid = paidA + 40_000_003 + 7_000_007;
        assertEq(toStaking, paidA / 10 + uint256(40_000_003) / 10 + uint256(7_000_007) / 10);
        assertEq(usdc.balanceOf(payout), paid - toStaking);
    }
}

/// @notice A wallet that writes to its own storage while being asked about a signature.
contract R3WritingWallet {
    uint256 public asked;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        ++asked;
        return 0x1626ba7e;
    }
}
