// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegentOffers, IRegentRevenueStaking} from "../../src/RegentOffers.sol";

/// @notice Review 3's own USDC stand-in, written from Circle's FiatTokenV2_2 rules rather than from
///         the author's test token. Blocklist: a blocked address can neither send, receive, spend an
///         approval, nor give or be given one. Signed authorizations (EIP-3009): one used-or-cancelled
///         mark per (authorizer, nonce) shared by transfer, receive and cancel; `receive` only from
///         its `to`; a signer with no code is checked by its key (65 bytes, low s, v 27 or 28), a
///         signer with code by a read-only ERC-1271 call.
contract R3USDC is ERC20 {
    error Blacklisted(address account);

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    mapping(address => bool) public blacklisted;
    mapping(address authorizer => mapping(bytes32 nonce => bool)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") {}

    modifier clear(address account) {
        if (blacklisted[account]) revert Blacklisted(account);
        _;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool on) external {
        blacklisted[account] = on;
    }

    function transfer(address to, uint256 value) public override clear(msg.sender) clear(to) returns (bool) {
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        clear(msg.sender)
        clear(from)
        clear(to)
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    function approve(address spender, uint256 value) public override clear(msg.sender) clear(spender) returns (bool) {
        return super.approve(spender, value);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external clear(from) clear(to) {
        _use(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external clear(from) clear(to) {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _use(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external {
        require(!authorizationState[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");
        _requireSigned(authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), signature);
        authorizationState[authorizer][nonce] = true;
    }

    function _use(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[from][nonce], "FiatTokenV2: authorization is used or canceled");
        _requireSigned(
            from, keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)), signature
        );
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _requireSigned(address signer, bytes32 structHash, bytes memory signature) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        require(_signedBy(signer, digest, signature), "FiatTokenV2: invalid signature");
    }

    function _signedBy(address signer, bytes32 digest, bytes memory signature) private view returns (bool) {
        if (signer.code.length == 0) {
            if (signature.length != 65) return false;
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return false;
            if (v != 27 && v != 28) return false;
            address got = ecrecover(digest, v, r, s);
            return got != address(0) && got == signer;
        }
        (bool ok, bytes memory answer) =
            signer.staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), digest, signature));
        return ok && answer.length >= 32 && abi.decode(answer, (bytes32)) == bytes32(bytes4(0x1626ba7e));
    }
}

/// @notice A contract wallet that accepts its owner key's plain signature over the digest.
contract R3Wallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view virtual returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
        (bytes32 r, bytes32 s) = abi.decode(signature[:64], (bytes32, bytes32));
        return ecrecover(digest, uint8(signature[64]), r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function run(address target, bytes calldata data) external returns (bytes memory answer) {
        require(msg.sender == owner, "not the wallet's owner");
        bool ok;
        (ok, answer) = target.call(data);
        require(ok, "wallet call failed");
    }
}

/// @notice Review 3's own staking stand-in: pulls exactly the deposit, or refuses.
contract R3Staking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    bool public refusing;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setRefusing(bool on) external {
        refusing = on;
    }

    function depositUSDC(uint256 amount, bytes32, bytes32) external returns (uint256) {
        require(!refusing, "STAKING_REFUSES");
        require(usdc.transferFrom(msg.sender, address(this), amount), "PULL_FAILED");
        return amount;
    }
}

/// @notice The one place review 3's tests touch the call that brings a bid's money in. When that
///         call changes, only this contract changes.
abstract contract Review3Entry is Test {
    R3USDC internal usdc;
    RegentOffers internal offers;
    uint256 internal salts;
    address internal relayer;

    /// @dev The key that signs for an address: its own for a plain account, its owner's for a wallet.
    mapping(address => uint256) internal keyOf;

    /// @dev Every named person in review 3's tests has a known key, so each can sign its own bids.
    function makeAddr(string memory name) internal virtual override returns (address addr) {
        uint256 key;
        (addr, key) = makeAddrAndKey(name);
        keyOf[addr] = key;
    }

    function _terms(bytes32 venue, bytes32 slot, uint96 amount, uint32 length, uint64 placeBy, bytes32 salt)
        internal
        pure
        returns (RegentOffers.Terms memory)
    {
        return RegentOffers.Terms({
            venue: venue,
            slot: slot,
            lane: 0,
            wordingHash: keccak256("review 3 wording"),
            amount: amount,
            length: length,
            placeBy: placeBy,
            salt: salt
        });
    }

    function _digest(
        address token,
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        (bool ok, bytes memory answer) = token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "no domain separator");
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                abi.decode(answer, (bytes32)),
                keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce))
            )
        );
    }

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev `from`'s signature for a bid on `t` in the market `market`, valid in the given window.
    function _signBid(
        uint256 key,
        address from,
        address market,
        RegentOffers.Terms memory t,
        uint256 validAfter,
        uint256 validBefore
    ) internal view returns (bytes memory) {
        return _sig(
            key,
            _digest(
                address(usdc),
                RECEIVE_TYPEHASH,
                from,
                market,
                t.amount,
                validAfter,
                validBefore,
                keccak256(abi.encode(market, t))
            )
        );
    }

    /// @dev Submits a signed bid from `submitter`. Never reverts.
    function _submit(
        address submitter,
        RegentOffers.Terms memory t,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        bytes memory signature
    ) internal returns (bool ok, bytes32 id, bytes memory why) {
        bytes memory answer;
        vm.prank(submitter);
        (ok, answer) =
            address(offers).call(abi.encodeCall(RegentOffers.bid, (t, from, validAfter, validBefore, signature)));
        if (ok) id = abi.decode(answer, (bytes32));
        else why = answer;
    }

    /// @dev `from` is given `amount`, signs a bid for it and a relayer with no role submits it.
    ///      Never reverts: `ok` says whether the bid was taken, `why` carries the refusal.
    function _enter(address from, bytes32 venue, bytes32 slot, uint96 amount, uint32 length, uint64 placeBy)
        internal
        returns (bool ok, bytes32 id, bytes memory why)
    {
        if (relayer == address(0)) relayer = address(uint160(uint256(keccak256("r3 relayer with no role"))));
        RegentOffers.Terms memory t = _terms(venue, slot, amount, length, placeBy, bytes32(++salts));
        usdc.mint(from, amount);
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        require(keyOf[from] != 0, "review 3: no key known for this bidder");
        bytes memory signature = _signBid(keyOf[from], from, address(offers), t, 0, validBefore);
        return _submit(relayer, t, from, 0, validBefore, signature);
    }

    function _rec(bytes32 id) internal view returns (RegentOffers.Bid memory) {
        (bool ok, bytes memory answer) = address(offers).staticcall(abi.encodeCall(offers.bids, (id)));
        require(ok, "bids read failed");
        return abi.decode(answer, (RegentOffers.Bid));
    }

    function _venueOf(bytes32 venue) internal view returns (RegentOffers.Venue memory v) {
        (v.admin, v.operator, v.moderator, v.payout, v.minimum, v.length) = offers.venues(venue);
    }
}

/// @notice One venue set up the way the README describes, with every key a different address.
abstract contract Review3Base is Review3Entry {
    R3Staking internal staking;

    address internal owner = makeAddr("r3 owner");
    address internal admin = makeAddr("r3 venue admin");
    address internal operator = makeAddr("r3 operator");
    address internal moderator = makeAddr("r3 moderator");
    address internal payout = makeAddr("r3 payout");
    address internal bidder = makeAddr("r3 bidder");
    address internal bidder2 = makeAddr("r3 bidder 2");
    address internal site = makeAddr("r3 site's own bidding wallet");
    address internal stranger = makeAddr("r3 stranger");
    address internal thief = makeAddr("r3 thief");

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("forum#1");
    uint96 internal constant MINIMUM = 1_000_000;
    uint32 internal constant LENGTH = 72 hours;
    uint256 internal constant PROTOCOL_BPS = 1000;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdc = new R3USDC();
        staking = new R3Staking(usdc);
        offers = new RegentOffers(usdc, staking, PROTOCOL_BPS, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// @dev A bid on VENUE at its current length, to be placed within an hour.
    function _bid(address from, bytes32 slot, uint96 amount) internal returns (bytes32 id) {
        bool ok;
        (ok, id,) = _enter(from, VENUE, slot, amount, _venueOf(VENUE).length, uint64(_now() + 1 hours));
        require(ok, "bid refused");
    }

    function _placed(address from, bytes32 slot, uint96 amount) internal returns (bytes32 id) {
        id = _bid(from, slot, amount);
        vm.prank(_venueOf(VENUE).operator);
        offers.place(id);
    }

    function _status(bytes32 id) internal view returns (RegentOffers.Status) {
        return _rec(id).status;
    }
}
