// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IRegentRevenueStaking} from "../src/RegentOffers.sol";

/// @notice Stands in for USDC v2.2 as RegentOffers uses it: six decimals, EIP-3009
///         `receiveWithAuthorization` with a `bytes` signature checked for accounts and ERC-1271
///         wallets, one use per nonce and payer, only `to` may submit, and addresses that may
///         not receive USDC.
contract OffersTestUSDC is ERC20, EIP712 {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    mapping(address => bool) public blocked;

    constructor() ERC20("USD Coin", "USDC") EIP712("USD Coin", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[from][nonce], "FiatTokenV2: authorization is used or canceled");
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
        require(SignatureChecker.isValidSignatureNow(from, digest, signature), "FiatTokenV2: invalid signature");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}

/// @notice Stands in for the REGENT revenue staking contract: pulls the deposit, can be paused,
///         and can be made to pull short.
contract OffersTestStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    bool public paused;
    uint256 public shortBy;
    bytes32 public lastSourceTag;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    /// @notice Makes the next deposits pull `shortBy_` less than asked, as a faulty contract would.
    function setShortBy(uint256 shortBy_) external {
        shortBy = shortBy_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32) external returns (uint256) {
        require(!paused, "PAUSED");
        lastSourceTag = sourceTag;
        require(usdc.transferFrom(msg.sender, address(this), amount - shortBy), "PULL_FAILED");
        return amount;
    }
}

/// @notice A contract wallet that accepts any signature its owner key made over a digest (ERC-1271).
contract OffersTestWallet {
    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return SignatureChecker.isValidSignatureNow(signer, digest, signature) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
