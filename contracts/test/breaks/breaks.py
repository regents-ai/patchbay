"""Break RegentOffers on purpose and check that the offline tests catch every break.

Each break is a small edit to a copy of src/RegentOffers.sol in a fresh temporary folder; the
working tree is never touched. The unit, key and role tests run first; only a break they miss
runs the invariant suite. A break is caught when at least one test fails. A break whose text no
longer matches the contract, or that no longer builds, is an error: update it with the contract.

Run from the repository root:

    uv run --no-project contracts/test/breaks/breaks.py            # every break
    uv run --no-project contracts/test/breaks/breaks.py M04 N3a    # some breaks
    uv run --no-project contracts/test/breaks/breaks.py --list

The exit code is 0 only when every break chosen is caught.
"""

import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CONTRACTS = Path(__file__).resolve().parents[2]
SOURCE = "src/RegentOffers.sol"
UNIT = ["--match-path", "test/RegentOffers*", "--no-match-contract", "RegentOffersInvariantTest"]
INVARIANT = ["--match-contract", "RegentOffersInvariantTest"]
# Forge runs wait while another full check or forge run is going on this machine.
BUSY = r"make check|mix test|playwright|forge "

REMOVE = "        if (msg.sender != venues[b.venue].moderator) revert NotModerator();"
PLACE_CHECKS = "        if (block.timestamp >= b.placeBy) revert PlaceByPassed();"
RETURN_CHECKS = "        _onlyOperator(b.venue);\n        b.status = Status.Returned;"
SURPLUS = "amount = usdc.balanceOf(address(this)) - (totalCommitted + totalOwed + revenueOwed);"

# id -> (what the break does, [(text, replacement, times it must appear)])
BREAKS = {
    "M01": ("the venue admin may also remove", [
        (REMOVE, "        if (msg.sender != venues[b.venue].moderator && msg.sender != venues[b.venue].admin) revert NotModerator();", 1),
    ]),
    "M02": ("the owner may also remove", [
        (REMOVE, "        if (msg.sender != venues[b.venue].moderator && msg.sender != owner()) revert NotModerator();", 1),
    ]),
    "M03": ("anyone may replace a venue's admin", [
        ("function setVenueAdmin(bytes32 venue, address admin) external onlyOwner {",
         "function setVenueAdmin(bytes32 venue, address admin) external {", 1),
    ]),
    "M04": ("staking is left an unlimited approval", [
        ("usdc.forceApprove(address(staking), amount);", "usdc.forceApprove(address(staking), type(uint256).max);", 1),
    ]),
    "M05": ("the Ended event names the venue's current wallet, not the bid's", [
        ("emit Ended(bidId, reason, paid, returned, protocolShare, venueShare, payout);",
         "emit Ended(bidId, reason, paid, returned, protocolShare, venueShare, venues[b.venue].payout);", 1),
    ]),
    "M06": ("the BidPlaced event carries half the amount", [
        ("            terms.wordingHash,\n            terms.amount,\n",
         "            terms.wordingHash,\n            terms.amount / 2,\n", 1),
    ]),
    "M07": ("setTerms takes a zero minimum or length", [
        ("        if (minimum == 0 || length == 0) revert ZeroValue();\n", "", 1),
    ]),
    "M08": ("addVenue takes a zero minimum or length", [
        ("if (venue == bytes32(0) || minimum == 0 || length == 0) revert ZeroValue();",
         "if (venue == bytes32(0)) revert ZeroValue();", 1),
    ]),
    "M09": ("setVenueAdmin takes the zero address", [
        ("        if (admin == address(0)) revert ZeroAddress();\n", "", 1),
    ]),
    "M10": ("setOperator takes the zero address", [
        ("        if (operator == address(0)) revert ZeroAddress();\n", "", 1),
    ]),
    "M11": ("the venue admin may also set the payout wallet", [
        ("    function setPayout(bytes32 venue, address payout) external onlyOwner {\n        Venue storage v = _venue(venue);\n",
         "    function setPayout(bytes32 venue, address payout) external {\n        Venue storage v = _venue(venue);\n"
         "        if (msg.sender != owner()) _onlyVenueAdmin(venue);\n", 1),
    ]),
    "M12": ("an ending pays the venue's current wallet", [
        ("        address payout = b.payout;\n", "        address payout = venues[b.venue].payout;\n", 1),
    ]),
    "M13": ("a pause also stops withdrawals", [
        ("if (block.timestamp < b.placeBy) revert PlaceByNotPassed();",
         "if (block.timestamp < b.placeBy || paused) revert PlaceByNotPassed();", 1),
    ]),
    "M14": ("a replaced bid's payment rounds up, against the bidder", [
        ("paid = (amount * shown) / length;", "paid = (amount * shown + length - 1) / length;", 1),
    ]),
    "M15": ("setOperator may name the moderator", [
        ("        _checkSeparate(v.moderator, v.admin, operator);\n", "", 1),
    ]),
    "M16": ("the moderator may remove a bid never placed", [
        ("        if (b.status != Status.Placed) revert NotPlaced();\n" + REMOVE,
         "        if (b.status != Status.Placed && b.status != Status.Held) revert NotPlaced();\n" + REMOVE, 1),
    ]),
    "M17": ("setModerator takes the zero address", [
        ("        if (moderator == address(0)) revert ZeroAddress();\n", "", 1),
    ]),
    "M18": ("returnBid emits BidWithdrawn", [
        ("emit BidReturned(bidId, b.bidder, b.amount);", "emit BidWithdrawn(bidId, b.bidder, b.amount);", 1),
    ]),
    "N1a": ("only the venue admin sets the payout wallet, as before", [
        ("    function setPayout(bytes32 venue, address payout) external onlyOwner {\n        Venue storage v = _venue(venue);\n",
         "    function setPayout(bytes32 venue, address payout) external {\n        Venue storage v = _venue(venue);\n"
         "        _onlyVenueAdmin(venue);\n", 1),
    ]),
    "N1b": ("anyone may set the payout wallet", [
        ("function setPayout(bytes32 venue, address payout) external onlyOwner {",
         "function setPayout(bytes32 venue, address payout) external {", 1),
    ]),
    "N3a": ("addVenue may make the moderator the admin or the operator", [
        ("        _checkSeparate(moderator, admin, operator);\n", "", 1),
    ]),
    "N3b": ("setModerator may name the admin or the operator", [
        ("        _checkSeparate(moderator, v.admin, v.operator);\n", "", 1),
    ]),
    "N3c": ("setVenueAdmin may name the moderator", [
        ("        _checkSeparate(v.moderator, admin, v.operator);\n", "", 1),
    ]),
    "N3d": ("the moderator is kept apart from the operator only", [
        ("if (moderator == admin || moderator == operator) revert ModeratorNotSeparate();",
         "if (moderator == operator) revert ModeratorNotSeparate();", 1),
    ]),
    "N3e": ("the moderator is kept apart from the admin only", [
        ("if (moderator == admin || moderator == operator) revert ModeratorNotSeparate();",
         "if (moderator == admin) revert ModeratorNotSeparate();", 1),
    ]),
    "A3": ("the received-amount check is off", [
        ("if (usdc.balanceOf(address(this)) - before != terms.amount) revert AmountNotReceived();", "before;", 1),
    ]),
    "A4": ("the re-entry guard is off everywhere", [
        (" nonReentrant", "", 9),
    ]),
    "A5": ("the 72-hour cap on placeBy is off", [
        ("        if (terms.placeBy > block.timestamp + MAX_WAIT) revert PlaceByTooFar();\n", "", 1),
    ]),
    "A6": ("USDC and staking are accepted as payout wallets", [
        ("payout == address(this) || payout == address(usdc) || payout == address(staking)", "payout == address(this)", 1),
    ]),
    "A7": ("a replacement pays the whole bid, as a removal does", [
        ("            paid = (amount * shown) / length;\n", "            paid = amount;\n", 1),
    ]),
    "A8": ("the operator may also remove", [
        (REMOVE, "        if (msg.sender != venues[b.venue].moderator && msg.sender != venues[b.venue].operator) revert NotModerator();", 1),
    ]),
    "A9": ("a pause no longer stops new bids", [
        ("        if (paused) revert BidsPaused();\n", "", 1),
    ]),
    "S1": ("the submitter is recorded as the bidder", [
        ("bidId = bidIdOf(bidder, terms);", "bidId = bidIdOf(msg.sender, terms);", 1),
        ("            bidder: bidder,\n", "            bidder: msg.sender,\n", 1),
    ]),
    "S2": ("the money is taken from the submitter", [
        ("                bidder, address(this), terms.amount, validAfter, validBefore, nonceOf(terms), signature",
         "                msg.sender, address(this), terms.amount, validAfter, validBefore, nonceOf(terms), signature", 1),
    ]),
    "S3": ("the bid id leaves out the bidder", [
        ("return keccak256(abi.encode(bidder, terms));", "return keccak256(abi.encode(terms));", 1),
    ]),
    "S4": ("the nonce leaves out the wording", [
        ("        return keccak256(abi.encode(address(this), terms));\n",
         "        return keccak256(\n            abi.encode(address(this), terms.venue, terms.slot, terms.lane, terms.amount, terms.length, terms.placeBy, terms.salt)\n        );\n", 1),
    ]),
    "S5": ("the nonce is the bidder's salt alone", [
        ("        return keccak256(abi.encode(address(this), terms));\n", "        return terms.salt;\n", 1),
    ]),
    "S6": ("the bidder's time window is swapped for an open one", [
        ("terms.amount, validAfter, validBefore, nonceOf(terms), signature",
         "terms.amount, 0, type(uint256).max, nonceOf(terms), signature", 1),
    ]),
    "S7": ("only the venue's operator may submit a bid", [
        ("        Venue storage v = _venue(terms.venue);\n        if (terms.amount < v.minimum) revert BelowMinimum();",
         "        Venue storage v = _venue(terms.venue);\n        _onlyOperator(terms.venue);\n        if (terms.amount < v.minimum) revert BelowMinimum();", 1),
    ]),
    # Round 5: the pause stops new bids only.
    "P1": ("a pause also stops placing and replacing", [
        (PLACE_CHECKS, PLACE_CHECKS + "\n        if (paused) revert BidsPaused();", 1),
    ]),
    "P2": ("a pause also stops returns", [
        (RETURN_CHECKS, RETURN_CHECKS + "\n        if (paused) revert BidsPaused();", 1),
    ]),
    "P3": ("a pause also stops removals", [
        (REMOVE, REMOVE + "\n        if (paused) revert BidsPaused();", 1),
    ]),
    # Round 5: a signature is good for at most an hour after it is submitted.
    "W1": ("the one-hour cap on a signature's window is off", [
        ("        if (validBefore > block.timestamp + MAX_SIGNATURE_WINDOW) revert SignatureWindowTooLong();\n", "", 1),
    ]),
    "W2": ("the cap on a signature's window is two hours", [
        ("validBefore > block.timestamp + MAX_SIGNATURE_WINDOW",
         "validBefore > block.timestamp + 2 * MAX_SIGNATURE_WINDOW", 1),
    ]),
    # Round 5: the nonce names the market.
    "N4": ("the nonce leaves out the market", [
        ("        return keccak256(abi.encode(address(this), terms));\n", "        return keccak256(abi.encode(terms));\n", 1),
    ]),
    # Round 5: recoverSurplus moves only what is above every liability, for the owner, to a wallet.
    "R1": ("recoverSurplus pays out the whole balance", [
        (SURPLUS, "amount = usdc.balanceOf(address(this));", 1),
    ]),
    "R2": ("recoverSurplus leaves out the bids held and placed", [
        (SURPLUS, "amount = usdc.balanceOf(address(this)) - (totalOwed + revenueOwed);", 1),
    ]),
    "R3": ("recoverSurplus leaves out what accounts are owed", [
        (SURPLUS, "amount = usdc.balanceOf(address(this)) - (totalCommitted + revenueOwed);", 1),
    ]),
    "R4": ("recoverSurplus leaves out the staking share", [
        (SURPLUS, "amount = usdc.balanceOf(address(this)) - (totalCommitted + totalOwed);", 1),
    ]),
    "R5": ("anyone may recover the surplus", [
        ("function recoverSurplus(address to) external nonReentrant onlyOwner",
         "function recoverSurplus(address to) external nonReentrant", 1),
    ]),
    "R6": ("the surplus may go to the zero address or a party", [
        ("        _checkPayout(to);\n        amount = usdc", "        amount = usdc", 1),
    ]),
}


def wait_while_busy():
    while subprocess.run(["pgrep", "-f", BUSY], capture_output=True).returncode == 0:
        print("   waiting: another check is running", flush=True)
        time.sleep(30)


def forge_test(root, selection):
    wait_while_busy()
    run = subprocess.run(["forge", "test", "--offline", *selection], cwd=root, capture_output=True, text=True)
    out = run.stdout + run.stderr
    counts = re.search(r"(\d+) tests passed, (\d+) failed", out)
    # A fuzz failure's line carries its arguments in brackets, so the name is the last word
    # before an opening parenthesis.
    failing = sorted(set(re.findall(r"^\[FAIL.*\] (\w+)\(", out, re.M)))
    return counts is not None, failing, out


def broken_copy(edits, into):
    for part in ("src", "test", "script"):
        shutil.copytree(CONTRACTS / part, into / part)
    for part in ("foundry.toml", "remappings.txt"):
        shutil.copy2(CONTRACTS / part, into / part)
    for part in ("out", "cache"):
        if (CONTRACTS / part).is_dir():
            shutil.copytree(CONTRACTS / part, into / part)
    (into / "lib").symlink_to(CONTRACTS / "lib")
    path = into / SOURCE
    text = path.read_text()
    for old, new, times in edits:
        found = text.count(old)
        if found != times:
            return f"its text appears {found} times, not {times}: {old.strip()[:70]}"
        text = text.replace(old, new)
    path.write_text(text)
    return None


def check(key):
    what, edits = BREAKS[key]
    with tempfile.TemporaryDirectory(prefix=f"offers-break-{key}-") as folder:
        root = Path(folder)
        problem = broken_copy(edits, root)
        if problem:
            return "ERROR", [problem]
        built, failing, out = forge_test(root, UNIT)
        if not built:
            return "ERROR", ["does not build: " + out.strip().splitlines()[-1][:120]]
        if failing:
            return "caught", failing
        built, failing, out = forge_test(root, INVARIANT)
        if failing:
            return "caught (invariant)", failing
        return "MISSED", []


def main(argv):
    if "--list" in argv:
        for key, (what, _) in BREAKS.items():
            print(f"{key:4} {what}")
        return 0
    chosen = argv or list(BREAKS)
    unknown = [k for k in chosen if k not in BREAKS]
    if unknown:
        print("unknown breaks: " + " ".join(unknown))
        return 2
    bad = 0
    for key in chosen:
        verdict, tests = check(key)
        bad += verdict in ("MISSED", "ERROR")
        print(f"{key:4} {verdict:18} {BREAKS[key][0]}", flush=True)
        for test in tests[:4]:
            print(f"       {test}")
        if len(tests) > 4:
            print(f"       and {len(tests) - 4} more")
    print(f"{len(chosen) - bad} of {len(chosen)} breaks caught")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
