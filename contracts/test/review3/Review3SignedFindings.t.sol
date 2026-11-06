// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegentOffers} from "../../src/RegentOffers.sol";
import {Review3Base, R3USDC} from "./Review3Base.sol";

/// @notice Review 3, the signed entry call: the things that are true of it and are not said, or not
///         enforced. Each test passes on the reviewed code and shows the behaviour in its name.
contract Review3SignedFindingsTest is Review3Base {
    uint256 internal constant WINDOW = 10 minutes;
    uint96 internal constant AMOUNT = 72_000_000;

    function setUp() public override {
        super.setUp();
        relayer = makeAddr("r3 relayer");
    }

    function _send(RegentOffers.Terms memory t, address from, uint256 validBefore, bytes memory signature)
        internal
        returns (bool ok, bytes32 id, bytes memory why)
    {
        return _submit(relayer, t, from, 0, validBefore, signature);
    }

    /// @notice F11 (note). The signature names the bidder's side of the bid only. Who is paid, and
    ///         who may remove, are whatever the owner has named when the signature is submitted,
    ///         not what the bidder saw when signing.
    function test_R3_F11_the_signature_does_not_name_who_is_paid_or_who_may_remove() public {
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        usdc.mint(bidder, AMOUNT);
        assertEq(_venueOf(VENUE).payout, payout, "what the bidder saw");

        // Between the signing and the submission, the owner key names new wallets.
        address payout2 = makeAddr("r3 payout named after signing");
        address moderator2 = makeAddr("r3 moderator named after signing");
        vm.startPrank(owner);
        offers.setPayout(VENUE, payout2);
        offers.setModerator(VENUE, moderator2);
        vm.stopPrank();

        (bool ok, bytes32 id,) = _send(t, bidder, validBefore, signature);
        assertTrue(ok, "the same signature still makes the bid");
        assertEq(_rec(id).payout, payout2, "paid to a wallet named after the bidder signed");
        vm.prank(operator);
        offers.place(id);
        vm.prank(moderator2);
        offers.remove(id);
        assertEq(offers.owed(payout2), (uint256(AMOUNT) * 9) / 10);
        assertEq(offers.owed(payout), 0);
        assertEq(offers.owed(bidder), 0);
    }

    /// @notice F12 (low), fixed in round 5. A bid is refused while its signature is good for more
    ///         than MAX_SIGNATURE_WINDOW (one hour) after it is submitted. The contract cannot tell
    ///         when a signature was made, so one with a far deadline still works in its last hour:
    ///         the site asks for deadlines within the hour, and the wallet prompt shows the deadline.
    function test_R3_F12_a_signature_with_a_far_deadline_works_only_in_its_last_hour() public {
        uint64 placeBy = uint64(_now() + 30 days);
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, placeBy, bytes32(++salts));
        bytes memory signature = _signBid(keyOf[bidder], bidder, address(offers), t, 0, placeBy);
        usdc.mint(bidder, AMOUNT);

        (bool ok,, bytes memory why) = _send(t, bidder, placeBy, signature);
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.PlaceByTooFar.selector);

        vm.warp(_now() + 27 days);
        (ok,, why) = _send(t, bidder, placeBy, signature);
        assertFalse(ok, "72 hours before its place-by, the deadline is still too far");
        assertEq(bytes4(why), RegentOffers.SignatureWindowTooLong.selector);

        vm.warp(placeBy - offers.MAX_SIGNATURE_WINDOW() - 1);
        (ok,, why) = _send(t, bidder, placeBy, signature);
        assertFalse(ok, "one second more than an hour before its deadline");
        assertEq(bytes4(why), RegentOffers.SignatureWindowTooLong.selector);
        assertEq(usdc.balanceOf(bidder), AMOUNT, "nothing taken while refused");

        vm.warp(_now() + 1);
        vm.prank(thief);
        bytes32 id = offers.bid(t, bidder, 0, placeBy, signature);
        assertEq(usdc.balanceOf(bidder), 0, "in its last hour a kept signature still makes its bid");
        assertEq(uint8(_status(id)), uint8(RegentOffers.Status.Held));
    }

    /// @notice F13 (low). An account that has been upgraded (EIP-7702) to code with no signature
    ///         answer cannot bid at all, and a signature it made as a plain account stops working
    ///         the moment it upgrades. Nothing is charged; the bid simply cannot be made.
    function test_R3_F13_an_upgraded_account_with_no_signature_answer_cannot_bid() public {
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        uint256 validBefore = _now() + WINDOW;
        bytes memory signature = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        usdc.mint(bidder, AMOUNT);

        // The account now runs a delegate's code (stood in for by placing that code at its address).
        vm.etch(bidder, address(new R3SilentDelegate()).code);
        (bool ok,, bytes memory why) = _send(t, bidder, validBefore, signature);
        assertFalse(ok, "a correct signature by the account's own key is refused");
        assertEq(_reason(why), "FiatTokenV2: invalid signature");
        vm.etch(bidder, address(new R3QuietDelegate()).code);
        (ok,,) = _send(t, bidder, validBefore, signature);
        assertFalse(ok, "the same with a delegate that accepts any call and answers nothing");
        assertEq(usdc.balanceOf(bidder), AMOUNT, "nothing was charged");

        // Back to a plain account: the very same signature works.
        vm.etch(bidder, "");
        (ok,,) = _send(t, bidder, validBefore, signature);
        assertTrue(ok);
    }

    /// @notice F14 (low). A contract wallet decides, at the moment of the call, whether its
    ///         signature is good. It can say yes when the site checks and no when the site sends,
    ///         and burn nearly all the gas the sender allowed while saying no. The sender (the
    ///         site's paymaster) pays; no bid is made and no bidder money moves.
    function test_R3_F14_a_hostile_wallet_makes_the_sender_pay_for_nothing() public {
        R3MoodyWallet wallet = new R3MoodyWallet();
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        uint256 validBefore = _now() + WINDOW;
        usdc.mint(address(wallet), AMOUNT);
        bytes memory data = abi.encodeCall(RegentOffers.bid, (t, address(wallet), 0, validBefore, ""));

        // The site's check before sending: it would work.
        wallet.set(true);
        uint256 snap = vm.snapshotState();
        vm.prank(relayer);
        (bool ok,) = address(offers).call(data);
        assertTrue(ok, "the check before sending says the bid will be taken");
        vm.revertToState(snap);

        // The wallet changes its mind before the transaction lands.
        wallet.set(false);
        uint256 allowed = 2_000_000;
        vm.prank(relayer);
        uint256 before = gasleft();
        (ok,) = address(offers).call{gas: allowed}(data);
        uint256 used = before - gasleft();
        assertFalse(ok, "the sent transaction fails");
        assertGt(used, (allowed * 95) / 100, "and burns more than 95% of the gas the sender allowed");
        assertEq(usdc.balanceOf(address(wallet)), AMOUNT);
        assertEq(offers.totalCommitted(), 0);
    }

    /// @notice F15 (note). USDC, not this contract, decides whose signature is good. A wallet whose
    ///         signature check accepts anything can be bid for by anyone, on any terms: its USDC is
    ///         moved into a bid by a stranger. It comes back after place-by unless the venue's keys
    ///         place and remove it first.
    function test_R3_F15_a_careless_wallet_can_be_bid_for_by_anyone() public {
        R3CarelessWallet wallet = new R3CarelessWallet();
        usdc.mint(address(wallet), 500_000_000);
        RegentOffers.Terms memory t =
            _terms(VENUE, SLOT, 500_000_000, LENGTH, uint64(_now() + 72 hours), bytes32(++salts));
        vm.prank(thief);
        // Round 5: the window is at most an hour; the careless wallet still accepts anything.
        bytes32 id = offers.bid(t, address(wallet), 0, _now() + WINDOW, "");
        assertEq(usdc.balanceOf(address(wallet)), 0, "a stranger moved all of the wallet's USDC into a bid");
        assertEq(_rec(id).bidder, address(wallet));
        // Left alone it comes back, to the wallet only, after the longest wait.
        vm.warp(t.placeBy);
        offers.withdraw(id);
        offers.payOut(address(wallet));
        assertEq(usdc.balanceOf(address(wallet)), 500_000_000);
        assertEq(usdc.balanceOf(thief), 0);
    }

    /// @notice F16 (note), fixed in round 5. The nonce names the market, so the same bidder's equal
    ///         terms on another market with the same venue id are their own signature: using one
    ///         never blocks the other, and neither signature works on the other market.
    function test_R3_F16_equal_terms_on_a_second_market_are_their_own_bid() public {
        RegentOffers second = new RegentOffers(usdc, staking, PROTOCOL_BPS, owner);
        vm.prank(owner);
        second.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);

        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        uint256 validBefore = _now() + WINDOW;
        bytes memory forFirst = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        bytes memory forSecond = _signBid(keyOf[bidder], bidder, address(second), t, 0, validBefore);
        usdc.mint(bidder, 2 * uint256(AMOUNT));
        assertTrue(offers.nonceOf(t) != second.nonceOf(t));

        vm.prank(thief);
        (bool ok,) = address(second).call(abi.encodeCall(RegentOffers.bid, (t, bidder, 0, validBefore, forFirst)));
        assertFalse(ok, "the first market's signature does not work on the second");
        vm.prank(thief);
        offers.bid(t, bidder, 0, validBefore, forFirst);
        vm.prank(relayer);
        second.bid(t, bidder, 0, validBefore, forSecond);
        assertEq(usdc.balanceOf(address(offers)), AMOUNT);
        assertEq(usdc.balanceOf(address(second)), AMOUNT, "the bid the bidder wanted on the second market is made");
    }

    /// @notice F17 (note). What the bidder's wallet is asked to sign shows the market, the amount
    ///         and the deadline. The venue, slot, wording, length and place-by are inside one
    ///         32-byte number the wallet cannot explain. Two very different bids look the same.
    function test_R3_F17_the_wallet_prompt_cannot_show_what_is_being_bid_on() public view {
        uint256 validBefore = _now() + WINDOW;
        RegentOffers.Terms memory shown =
            _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(uint256(1)));
        RegentOffers.Terms memory signedInstead = _terms(
            VENUE, keccak256("a slot nobody reads"), AMOUNT, LENGTH, uint64(_now() + 72 hours), bytes32(uint256(1))
        );
        signedInstead.wordingHash = keccak256("wording the bidder never saw");
        // The six fields of the message the wallet displays: from, to, value, validAfter, validBefore, nonce.
        bytes memory a = abi.encode(bidder, address(offers), shown.amount, uint256(0), validBefore);
        bytes memory b = abi.encode(bidder, address(offers), signedInstead.amount, uint256(0), validBefore);
        assertEq(a, b, "five of the six fields are identical");
        assertTrue(offers.nonceOf(shown) != offers.nonceOf(signedInstead), "only the opaque number differs");
    }

    /// @notice F18 (low). If a bidder is ever asked for the transfer form of the USDC signature (the
    ///         form x402 payments use) naming this contract, anyone can push the money in. No bid is
    ///         made, and the money is in no record; since round 5 only the owner's recoverSurplus
    ///         can send it back.
    function test_R3_F18_the_transfer_form_of_the_signature_strands_the_money() public {
        RegentOffers.Terms memory t = _terms(VENUE, SLOT, AMOUNT, LENGTH, uint64(_now() + 1 hours), bytes32(++salts));
        uint256 validBefore = _now() + WINDOW;
        bytes32 nonce = offers.nonceOf(t);
        bytes memory transferForm = _sig(
            keyOf[bidder],
            _digest(address(usdc), TRANSFER_TYPEHASH, bidder, address(offers), AMOUNT, 0, validBefore, nonce)
        );
        usdc.mint(bidder, AMOUNT);

        (bool ok,,) = _send(t, bidder, validBefore, transferForm);
        assertFalse(ok, "the market refuses it as a bid");
        vm.prank(stranger);
        usdc.transferWithAuthorization(bidder, address(offers), AMOUNT, 0, validBefore, nonce, transferForm);
        assertEq(usdc.balanceOf(bidder), 0);
        assertEq(usdc.balanceOf(address(offers)), AMOUNT, "the money is in the market");
        assertEq(offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(), 0, "in no record");
        assertEq(uint8(_status(offers.bidIdOf(bidder, t))), uint8(RegentOffers.Status.None), "and there is no bid");
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        offers.payOut(bidder);
        // The bidder cannot even bid the same terms afterwards: the nonce is spent.
        bytes memory receiveForm = _signBid(keyOf[bidder], bidder, address(offers), t, 0, validBefore);
        usdc.mint(bidder, AMOUNT);
        (ok,,) = _send(t, bidder, validBefore, receiveForm);
        assertFalse(ok);

        // Round 5: the owner can send the stranded money back, and nothing else.
        vm.prank(owner);
        assertEq(offers.recoverSurplus(bidder), AMOUNT);
        assertEq(usdc.balanceOf(bidder), 2 * uint256(AMOUNT));
        assertEq(usdc.balanceOf(address(offers)), 0);
    }

    function _reason(bytes memory why) internal pure returns (string memory) {
        if (why.length < 68) return "";
        bytes memory rest = new bytes(why.length - 4);
        for (uint256 i; i < rest.length; ++i) {
            rest[i] = why[i + 4];
        }
        return abi.decode(rest, (string));
    }
}

/// @notice Code with no answer about signatures: any call to it fails.
contract R3SilentDelegate {
    receive() external payable {}
}

/// @notice Code that accepts any call and answers nothing.
contract R3QuietDelegate {
    fallback() external payable {}
}

/// @notice A wallet whose owner switches its answer, and that burns gas when the answer is no.
contract R3MoodyWallet {
    bool internal yes;

    function set(bool yes_) external {
        yes = yes_;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (yes) return 0x1626ba7e;
        while (gasleft() > 10_000) {}
        return 0xffffffff;
    }
}

/// @notice A wallet whose signature check accepts anything.
contract R3CarelessWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
