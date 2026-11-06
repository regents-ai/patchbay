// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {RegentOffers} from "../../src/RegentOffers.sol";
import {Review3Base, R3USDC, R3Staking, R3Wallet} from "./Review3Base.sol";

/// @notice Review 3, the signed entry call: what a signature can and cannot be made to do. Offline,
///         against review 3's own stand-in for USDC's signed-authorization rules. The same attacks
///         are repeated against the real Base USDC in Review3Fork.t.sol.
contract Review3SignedTest is Review3Base {
    uint256 internal constant WINDOW = 10 minutes;
    uint96 internal constant AMOUNT = 72_000_000;

    struct Signed {
        RegentOffers.Terms t;
        address from;
        uint256 validAfter;
        uint256 validBefore;
        bytes signature;
        bytes32 id;
    }

    function setUp() public override {
        super.setUp();
        relayer = makeAddr("r3 relayer");
    }

    /// @dev `from` has the money and has signed; nothing is submitted yet.
    function _signed(address from, bytes32 slot, uint96 amount) internal returns (Signed memory s) {
        s.t = _terms(VENUE, slot, amount, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        s.from = from;
        s.validAfter = 0;
        s.validBefore = _now() + WINDOW;
        s.signature = _signBid(keyOf[from], from, address(offers), s.t, 0, s.validBefore);
        s.id = offers.bidIdOf(from, s.t);
        usdc.mint(from, amount);
    }

    function _send(address submitter, Signed memory s) internal returns (bool ok, bytes memory why) {
        (ok,, why) = _submit(submitter, s.t, s.from, s.validAfter, s.validBefore, s.signature);
    }

    struct Books {
        uint256 committed;
        uint256 owed;
        uint256 revenue;
        uint256 market;
        uint256 bidder;
    }

    function _books(address from) internal view returns (Books memory b) {
        b = Books(
            offers.totalCommitted(),
            offers.totalOwed(),
            offers.revenueOwed(),
            usdc.balanceOf(address(offers)),
            usdc.balanceOf(from)
        );
    }

    function _assertUntouched(Books memory before, address from, bytes32 id, string memory what) internal view {
        Books memory b = _books(from);
        assertEq(b.committed, before.committed, what);
        assertEq(b.owed, before.owed, what);
        assertEq(b.revenue, before.revenue, what);
        assertEq(b.market, before.market, what);
        assertEq(b.bidder, before.bidder, what);
        assertEq(uint8(_status(id)), uint8(RegentOffers.Status.None), what);
    }

    // ------------------------------------------------------------------ a) what a signature buys

    /// @notice HELD. One signature buys one bid: the bidder, market and every term it was signed for.
    function test_R3_S1_a_signature_buys_only_the_bid_that_was_signed() public {
        // A second venue with the same settings, and a second market with the same venue.
        bytes32 twin = keccak256("twin venue");
        vm.prank(owner);
        offers.addVenue(twin, admin, operator, moderator, payout, MINIMUM, LENGTH);
        RegentOffers other = new RegentOffers(usdc, staking, PROTOCOL_BPS, owner);
        vm.prank(owner);
        other.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);

        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        usdc.mint(bidder, 10 * AMOUNT); // more than enough for any altered amount
        usdc.mint(bidder2, 10 * AMOUNT);
        Books memory before = _books(bidder);

        Signed memory x = _copy(s);
        x.t.venue = twin;
        _refused(x, "another venue");
        x = _copy(s);
        x.t.slot = keccak256("forum#2");
        _refused(x, "another slot");
        x = _copy(s);
        x.t.lane = 1;
        _refused(x, "another lane");
        x = _copy(s);
        x.t.wordingHash = keccak256("other wording");
        _refused(x, "another wording");
        x = _copy(s);
        x.t.amount = AMOUNT + 1;
        _refused(x, "a larger amount");
        x = _copy(s);
        x.t.amount = AMOUNT - 1;
        _refused(x, "a smaller amount");
        x = _copy(s);
        x.t.placeBy += 1;
        _refused(x, "a longer wait");
        x = _copy(s);
        x.t.placeBy -= 1;
        _refused(x, "a shorter wait");
        x = _copy(s);
        x.t.salt = bytes32(uint256(999));
        _refused(x, "another salt");
        x = _copy(s);
        x.from = bidder2;
        _refused(x, "another bidder");
        x = _copy(s);
        x.validBefore += 1;
        _refused(x, "a later deadline");
        x = _copy(s);
        x.validAfter = 1;
        _refused(x, "another start");

        // A changed length: first as-is (the venue refuses it), then with the venue's terms moved to match.
        x = _copy(s);
        x.t.length = LENGTH - 1;
        _refused(x, "another length");
        vm.prank(admin);
        offers.setTerms(VENUE, MINIMUM, LENGTH - 1);
        _refused(x, "another length the venue now uses");
        _refused(s, "the signed length the venue no longer uses");
        vm.prank(admin);
        offers.setTerms(VENUE, MINIMUM, LENGTH);

        // Another market with the same venue id.
        vm.prank(relayer);
        (bool ok,) = address(other).call(
            abi.encodeCall(RegentOffers.bid, (s.t, s.from, s.validAfter, s.validBefore, s.signature))
        );
        assertFalse(ok, "another market took the signature");
        assertEq(usdc.balanceOf(address(other)), 0);

        // Another chain.
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        _refused(s, "another chain");
        vm.chainId(chain);

        _assertUntouched(before, bidder, s.id, "nothing moved while every altered bid was refused");
        (ok,) = _send(relayer, s);
        assertTrue(ok, "the bid as signed is taken");
        assertEq(usdc.balanceOf(bidder), before.bidder - AMOUNT);
        assertEq(_rec(s.id).bidder, bidder);
    }

    function _copy(Signed memory s) internal pure returns (Signed memory x) {
        x = abi.decode(abi.encode(s), (Signed));
    }

    function _refused(Signed memory x, string memory what) internal {
        uint256 marketBefore = usdc.balanceOf(address(offers));
        (bool ok,) = _send(relayer, x);
        assertFalse(ok, what);
        assertEq(usdc.balanceOf(address(offers)), marketBefore, what);
        assertEq(uint8(_status(offers.bidIdOf(x.from, x.t))), uint8(RegentOffers.Status.None), what);
    }

    /// @notice HELD. Any single changed bit anywhere in the submitted call makes it fail.
    function testFuzz_R3_S2_one_changed_bit_anywhere_is_refused(uint256 where, uint8 bit) public {
        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        usdc.mint(bidder, type(uint96).max);
        bytes memory data = abi.encodeCall(RegentOffers.bid, (s.t, s.from, s.validAfter, s.validBefore, s.signature));
        // 4 selector bytes, 12 head words, 1 length word, 65 signature bytes; the padding after is not read.
        uint256 live = 12 * 32 + 32 + 65;
        where = 4 + bound(where, 0, live - 1);
        data[where] = data[where] ^ bytes1(uint8(1) << (bit % 8));
        Books memory before = _books(bidder);
        vm.prank(relayer);
        (bool ok,) = address(offers).call(data);
        assertFalse(ok, "a call one bit away from the signed one was taken");
        _assertUntouched(before, bidder, s.id, "one changed bit");
    }

    /// @notice HELD. Nobody but this market can spend or burn the signature at USDC.
    function test_R3_S3_a_watcher_cannot_spend_or_burn_the_signature_at_usdc() public {
        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        bytes32 nonce = offers.nonceOf(s.t);
        Books memory before = _books(bidder);

        vm.startPrank(thief);
        vm.expectRevert("FiatTokenV2: caller must be the payee");
        usdc.receiveWithAuthorization(bidder, address(offers), AMOUNT, 0, s.validBefore, nonce, s.signature);
        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.receiveWithAuthorization(bidder, thief, AMOUNT, 0, s.validBefore, nonce, s.signature);
        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.transferWithAuthorization(bidder, address(offers), AMOUNT, 0, s.validBefore, nonce, s.signature);
        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.transferWithAuthorization(bidder, thief, AMOUNT, 0, s.validBefore, nonce, s.signature);
        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.cancelAuthorization(bidder, nonce, s.signature);
        vm.stopPrank();

        assertFalse(usdc.authorizationState(bidder, nonce), "the nonce is still unused");
        _assertUntouched(before, bidder, s.id, "after every direct try");
        (bool ok,) = _send(relayer, s);
        assertTrue(ok, "the bid can still be made");
    }

    /// @notice HELD. A used signature is used for good, whatever became of its bid.
    function test_R3_S4_a_signature_is_never_taken_twice() public {
        Signed memory returned = _signed(bidder, SLOT, AMOUNT);
        Signed memory withdrawn = _signed(bidder, keccak256("forum#2"), AMOUNT);
        Signed memory ended = _signed(bidder, keccak256("forum#3"), AMOUNT);
        _mustSend(returned);
        _mustSend(withdrawn);
        _mustSend(ended);
        usdc.mint(bidder, 3 * AMOUNT); // money is there for a second charge if one were possible

        _twice(returned, "while held");
        vm.prank(operator);
        offers.returnBid(returned.id);
        _twice(returned, "after its return");
        offers.payOut(bidder);
        _twice(returned, "after its return was paid");

        vm.prank(operator);
        offers.place(ended.id);
        _twice(ended, "while showing");
        vm.prank(moderator);
        offers.remove(ended.id);
        _twice(ended, "after it ended");

        // The window is still open for all three (ten minutes); only the bids' own states changed.
        assertLt(_now(), withdrawn.validBefore);
        vm.warp(withdrawn.validBefore - 1);
        _twice(withdrawn, "one second before its deadline");
    }

    function _mustSend(Signed memory s) internal {
        (bool ok,) = _send(relayer, s);
        assertTrue(ok, "bid refused");
    }

    function _twice(Signed memory s, string memory what) internal {
        uint256 had = usdc.balanceOf(bidder);
        (bool ok, bytes memory why) = _send(thief, s);
        assertFalse(ok, what);
        assertEq(bytes4(why), RegentOffers.BidExists.selector, what);
        assertEq(usdc.balanceOf(bidder), had, what);
    }

    /// @notice HELD. The window's two edges, to the second, and a cancelled signature.
    function test_R3_S5_the_window_edges_and_cancelling() public {
        Signed memory s;
        s.t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        s.from = bidder;
        s.validAfter = _now() + 60;
        s.validBefore = _now() + 120;
        s.signature = _signBid(keyOf[bidder], bidder, address(offers), s.t, s.validAfter, s.validBefore);
        s.id = offers.bidIdOf(bidder, s.t);
        usdc.mint(bidder, AMOUNT);
        Books memory before = _books(bidder);

        (bool ok,) = _send(relayer, s);
        assertFalse(ok, "before its start");
        vm.warp(s.validAfter);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "at its start second");
        vm.warp(s.validBefore);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "at its deadline second");
        _assertUntouched(before, bidder, s.id, "outside the window");

        uint256 snap = vm.snapshotState();
        vm.warp(s.validAfter + 1);
        (ok,) = _send(relayer, s);
        assertTrue(ok, "one second after its start");
        vm.revertToState(snap);
        vm.warp(s.validBefore - 1);
        (ok,) = _send(relayer, s);
        assertTrue(ok, "one second before its deadline");
        vm.revertToState(snap);

        // Cancelled by the bidder's own signature, sent by anyone.
        vm.warp(s.validAfter + 1);
        bytes32 nonce = offers.nonceOf(s.t);
        bytes memory cancel = _sig(
            keyOf[bidder],
            keccak256(
                abi.encodePacked(
                    "\x19\x01", usdc.DOMAIN_SEPARATOR(), keccak256(abi.encode(CANCEL_TYPEHASH, bidder, nonce))
                )
            )
        );
        vm.prank(stranger);
        usdc.cancelAuthorization(bidder, nonce, cancel);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "after cancelling");
        // The same terms signed again are dead too: the cancel killed the terms, not one signature.
        s.validBefore += 1 hours;
        s.signature = _signBid(keyOf[bidder], bidder, address(offers), s.t, s.validAfter, s.validBefore);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "the same terms signed again after cancelling");
        _assertUntouched(before, bidder, s.id, "after cancelling");
    }

    // ------------------------------------------------------------- b) what a watcher can do to the signer

    /// @notice HELD. A watcher who sends the bid first makes exactly the bid the bidder signed.
    function test_R3_S6_a_front_run_makes_the_same_bid_and_nothing_else() public {
        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        usdc.mint(bidder, AMOUNT);
        (bool ok,) = _send(thief, s);
        assertTrue(ok);
        RegentOffers.Bid memory b = _rec(s.id);
        assertEq(b.bidder, bidder, "the bidder is the signer, not the sender");
        assertEq(b.payout, payout);
        assertEq(usdc.balanceOf(thief), 0);
        // The site's own copy now fails, and takes nothing more.
        bytes memory why;
        (ok, why) = _send(relayer, s);
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.BidExists.selector);
        assertEq(usdc.balanceOf(bidder), AMOUNT, "charged once");
        // Only the bidder is given it back.
        vm.warp(s.t.placeBy);
        vm.prank(thief);
        offers.withdraw(s.id);
        assertEq(offers.owed(bidder), AMOUNT);
        assertEq(offers.owed(thief), 0);
    }

    /// @notice HELD. Nobody can take a bidder's id first: an id needs that bidder's own signature.
    function test_R3_S7_two_bidders_with_equal_terms_never_collide() public {
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(uint256(7)));
        uint256 validBefore = _now() + WINDOW;
        usdc.mint(bidder, AMOUNT);
        usdc.mint(bidder2, AMOUNT);
        // A wallet that says yes to everything bids the very same terms first.
        R3YesWallet yes = new R3YesWallet();
        usdc.mint(address(yes), AMOUNT);
        (bool ok, bytes32 idYes,) = _submit(thief, t, address(yes), 0, validBefore, "");
        assertTrue(ok);
        (bool ok1, bytes32 id1) = _plain(bidder, t, validBefore);
        (bool ok2, bytes32 id2) = _plain(bidder2, t, validBefore);
        assertTrue(ok1 && ok2, "equal terms from two bidders are both taken");
        assertTrue(id1 != id2 && id1 != idYes && id2 != idYes);
        assertEq(_rec(id1).bidder, bidder);
        assertEq(_rec(id2).bidder, bidder2);
        assertEq(offers.nonceOf(t), keccak256(abi.encode(address(offers), t)));
        assertEq(offers.bidIdOf(bidder, t), keccak256(abi.encode(bidder, t)));
        assertEq(abi.encode(t).length, 8 * 32, "eight fixed words, nothing packed or variable");
    }

    function _plain(address from, RegentOffers.Terms memory t, uint256 validBefore)
        internal
        returns (bool ok, bytes32 id)
    {
        bytes memory signature = _signBid(keyOf[from], from, address(offers), t, 0, validBefore);
        (ok, id,) = _submit(relayer, t, from, 0, validBefore, signature);
    }

    // ------------------------------------------------------------- c) half-made bids

    /// @notice HELD. Whatever makes USDC refuse, nothing of the bid is left behind.
    function test_R3_S8_a_refused_payment_leaves_no_bid() public {
        // Not enough money.
        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        vm.prank(bidder);
        usdc.transfer(stranger, 1);
        Books memory before = _books(bidder);
        (bool ok,) = _send(relayer, s);
        assertFalse(ok, "one unit short");
        _assertUntouched(before, bidder, s.id, "one unit short");
        vm.prank(stranger);
        usdc.transfer(bidder, 1);

        // Bidder blocked by USDC, then the market blocked by USDC.
        before = _books(bidder);
        usdc.setBlacklisted(bidder, true);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "blocked bidder");
        usdc.setBlacklisted(bidder, false);
        usdc.setBlacklisted(address(offers), true);
        (ok,) = _send(relayer, s);
        assertFalse(ok, "blocked market");
        usdc.setBlacklisted(address(offers), false);
        _assertUntouched(before, bidder, s.id, "blocked");

        // A blocked sender of the transaction does not matter: USDC sees the market as the caller.
        usdc.setBlacklisted(relayer, true);
        (ok,) = _send(relayer, s);
        assertTrue(ok, "a blocked sender can still deliver the bid");
    }

    /// @notice HELD. A token that reports success but moves a different amount: the bid fails whole.
    function test_R3_S9_a_token_that_moves_the_wrong_amount_leaves_no_bid() public {
        R3SkewUSDC skew = new R3SkewUSDC();
        usdc = skew;
        staking = new R3Staking(skew);
        offers = new RegentOffers(skew, staking, PROTOCOL_BPS, owner);
        skew.aim(address(offers));
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);

        int256[4] memory skews = [int256(-1), 1, -int256(uint256(AMOUNT)), int256(uint256(AMOUNT))];
        for (uint256 i; i < skews.length; ++i) {
            Signed memory s = _signed(bidder, SLOT, AMOUNT);
            usdc.mint(bidder, AMOUNT);
            skew.setSkew(skews[i]);
            Books memory before = _books(bidder);
            (bool ok, bytes memory why) = _send(relayer, s);
            assertFalse(ok, "a wrong amount was accepted");
            assertEq(bytes4(why), RegentOffers.AmountNotReceived.selector);
            _assertUntouched(before, bidder, s.id, "wrong amount");
        }
        skew.setSkew(0);
        Signed memory good = _signed(bidder, SLOT, AMOUNT);
        _mustSend(good);
    }

    /// @notice HELD. If the token itself calls out while the bid is written and the money is not yet
    ///         in, the venue's own operator and payout wallet cannot place it, return it or be paid.
    function test_R3_S10_nothing_can_act_on_a_bid_while_its_money_is_arriving() public {
        R3CallingUSDC calling = new R3CallingUSDC();
        usdc = calling;
        staking = new R3Staking(calling);
        offers = new RegentOffers(calling, staking, PROTOCOL_BPS, owner);
        R3Insider insider = new R3Insider(offers);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, address(insider), moderator, address(insider), MINIMUM, LENGTH);

        // The insider has something owed, so a payout during the call would have money to take.
        Signed memory earlier = _signed(bidder2, keccak256("forum#2"), AMOUNT);
        _mustSend(earlier);
        insider.place(earlier.id);
        vm.warp(_now() + LENGTH);
        offers.finish(earlier.id);
        assertEq(offers.owed(address(insider)), (uint256(AMOUNT) * 9) / 10);

        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        insider.aim(s.id, bidder);
        calling.arm(address(offers), address(insider));
        _mustSend(s);
        calling.arm(address(0), address(0));

        assertEq(insider.attempts(), 8);
        assertEq(insider.refusedByGuard(), 8, "every call during the payment was refused");
        assertTrue(insider.sawHalfMade(), "the bid was already written while its money was still outside");
        assertEq(uint8(_status(s.id)), uint8(RegentOffers.Status.Held));
        assertEq(
            usdc.balanceOf(address(offers)), offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed()
        );
    }

    // ------------------------------------------------------------- d) contract wallets

    /// @notice HELD. A wallet asked about its signature cannot change anything: USDC asks read-only.
    ///         The wallet here is also the venue's operator and payout wallet.
    function test_R3_S11_a_wallet_asked_about_its_signature_cannot_act() public {
        R3ReenteringWallet wallet = new R3ReenteringWallet(offers);
        vm.prank(admin);
        offers.setOperator(VENUE, address(wallet));
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        usdc.mint(address(wallet), AMOUNT);
        wallet.aim(offers.bidIdOf(address(wallet), t));
        (bool ok, bytes32 id,) = _submit(relayer, t, address(wallet), 0, _now() + WINDOW, "");
        // The wallet says yes only if every one of its calls failed and it saw the half-made bid.
        assertTrue(ok, "the wallet got a call through, or did not see the bid");
        assertEq(uint8(_status(id)), uint8(RegentOffers.Status.Held));
        assertEq(offers.live(VENUE, SLOT), bytes32(0));
        assertEq(offers.owed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(offers)), AMOUNT);
        assertEq(offers.totalCommitted(), AMOUNT);
    }

    // ------------------------------------------------------------- pressing twice

    /// @notice HELD. The same bidder making the same terms twice is charged once and loses nothing;
    ///         a second bid needs a new salt, and then both are held and both can come back.
    function test_R3_S12_pressing_twice() public {
        // Same terms, same signature.
        Signed memory s = _signed(bidder, SLOT, AMOUNT);
        usdc.mint(bidder, AMOUNT);
        _mustSend(s);
        _twice(s, "the same signature again");
        // Same terms, signed again with a new window.
        Signed memory again = _copy(s);
        again.validBefore = s.validBefore + 5 minutes;
        again.signature = _signBid(keyOf[bidder], bidder, address(offers), again.t, 0, again.validBefore);
        _twice(again, "the same terms signed again");
        assertEq(usdc.balanceOf(bidder), AMOUNT, "charged once");

        // New salt: a second, separate bid.
        Signed memory second = _signed(bidder, SLOT, AMOUNT);
        vm.prank(bidder);
        usdc.transfer(stranger, AMOUNT); // leave exactly one amount
        _mustSend(second);
        assertTrue(second.id != s.id);
        assertEq(offers.totalCommitted(), 2 * uint256(AMOUNT));
        vm.warp(s.t.placeBy);
        offers.withdraw(s.id);
        offers.withdraw(second.id);
        offers.payOut(bidder);
        assertEq(usdc.balanceOf(bidder), 2 * uint256(AMOUNT), "both came back");

        // A signature that ran out unsent does not block the same terms signed again.
        Signed memory late = _signed(bidder2, SLOT, AMOUNT);
        vm.warp(late.validBefore);
        (bool ok,) = _send(relayer, late);
        assertFalse(ok);
        late.validBefore = _now() + WINDOW;
        late.signature = _signBid(keyOf[bidder2], bidder2, address(offers), late.t, 0, late.validBefore);
        _mustSend(late);
    }
}

/// @notice Says yes to any signature.
contract R3YesWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice A token that moves `skew` more or less than asked when money goes to the market.
contract R3SkewUSDC is R3USDC {
    int256 internal skew;
    address internal market;

    function aim(address market_) external {
        market = market_;
    }

    function setSkew(int256 skew_) external {
        skew = skew_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == market && from != address(0)) value = uint256(int256(value) + skew);
        super._update(from, to, value);
    }
}

/// @notice A token that calls an outsider just before it moves money into the market.
contract R3CallingUSDC is R3USDC {
    address internal market;
    address internal callee;

    function arm(address market_, address callee_) external {
        market = market_;
        callee = callee_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (callee != address(0) && to == market) R3Insider(callee).strike();
        super._update(from, to, value);
    }
}

/// @notice The venue's operator and payout wallet in one contract, called while a bid's money is
///         on its way in.
contract R3Insider {
    RegentOffers internal immutable offers;
    bytes32 internal arriving;
    address internal arrivingBidder;
    uint256 public attempts;
    uint256 public refusedByGuard;
    bool public sawHalfMade;

    constructor(RegentOffers offers_) {
        offers = offers_;
    }

    function place(bytes32 id) external {
        offers.place(id);
    }

    function aim(bytes32 arriving_, address bidder_) external {
        arriving = arriving_;
        arrivingBidder = bidder_;
    }

    function strike() external {
        (, uint96 amount,,,,,,, RegentOffers.Status status) = offers.bids(arriving);
        uint256 recorded = offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed();
        sawHalfMade =
            status == RegentOffers.Status.Held && offers.usdc().balanceOf(address(offers)) + amount == recorded;
        RegentOffers.Terms memory t;
        _try(abi.encodeCall(RegentOffers.place, (arriving)));
        _try(abi.encodeCall(RegentOffers.returnBid, (arriving)));
        _try(abi.encodeCall(RegentOffers.withdraw, (arriving)));
        _try(abi.encodeCall(RegentOffers.finish, (arriving)));
        _try(abi.encodeCall(RegentOffers.payOut, (address(this))));
        _try(abi.encodeCall(RegentOffers.payOut, (arrivingBidder)));
        _try(abi.encodeCall(RegentOffers.pushRevenue, ()));
        _try(abi.encodeCall(RegentOffers.bid, (t, address(this), 0, type(uint256).max, "")));
    }

    function _try(bytes memory data) internal {
        ++attempts;
        (bool ok, bytes memory why) = address(offers).call(data);
        if (!ok && bytes4(why) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector) ++refusedByGuard;
    }
}

/// @notice A contract wallet that, when asked about a signature, tries to act on the bid being made.
///         It answers yes only if it saw the bid already written and every call it made failed.
contract R3ReenteringWallet {
    RegentOffers internal immutable offers;
    bytes32 internal arriving;

    constructor(RegentOffers offers_) {
        offers = offers_;
    }

    function aim(bytes32 arriving_) external {
        arriving = arriving_;
    }

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        (,,,,,,,, RegentOffers.Status status) = offers.bids(arriving);
        if (status != RegentOffers.Status.Held) return 0xffffffff;
        bool any;
        any = _try(abi.encodeCall(RegentOffers.place, (arriving))) || any;
        any = _try(abi.encodeCall(RegentOffers.returnBid, (arriving))) || any;
        any = _try(abi.encodeCall(RegentOffers.withdraw, (arriving))) || any;
        any = _try(abi.encodeCall(RegentOffers.payOut, (address(this)))) || any;
        any = _try(abi.encodeCall(RegentOffers.pushRevenue, ())) || any;
        return any ? bytes4(0xffffffff) : bytes4(0x1626ba7e);
    }

    function _try(bytes memory data) internal returns (bool ok) {
        (ok,) = address(offers).call(data);
    }
}
