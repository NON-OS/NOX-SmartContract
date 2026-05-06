// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable}          from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA}                      from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReceiptSettlement} from "../interfaces/IReceiptSettlement.sol";
import {ICapsuleRegistry}   from "../interfaces/ICapsuleRegistry.sol";
import {IFeeRouter}         from "../interfaces/IFeeRouter.sol";

contract ReceiptSettlement is
    IReceiptSettlement,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE   = keccak256("CONFIG_ROLE");

    bytes32 public constant RECEIPT_TYPEHASH = keccak256(
        "Receipt(bytes32 capsuleId,address user,address publisher,uint256 amountNox,uint256 nonce,uint256 epoch,uint256 expiry,bytes32 receiptType)"
    );

    ICapsuleRegistry public capsuleRegistry;
    IFeeRouter       public feeRouter;
    address          public noxToken;
    uint256          public epochDuration;
    uint256          public epochZero;

    mapping(bytes32 => bool) private _used;

    uint256[40] private __gap;

    error ZeroAddress();
    error InvalidEpochDuration();
    error EmptyBatch();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address capsuleRegistry_,
        address feeRouter_,
        address noxToken_,
        uint256 epochDuration_
    ) external initializer {
        if (admin == address(0))            revert ZeroAddress();
        if (capsuleRegistry_ == address(0)) revert ZeroAddress();
        if (feeRouter_ == address(0))       revert ZeroAddress();
        if (noxToken_ == address(0))        revert ZeroAddress();
        if (epochDuration_ == 0)            revert InvalidEpochDuration();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("0xNOX Receipt Settlement", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);

        capsuleRegistry = ICapsuleRegistry(capsuleRegistry_);
        feeRouter       = IFeeRouter(feeRouter_);
        noxToken        = noxToken_;
        epochDuration   = epochDuration_;
        epochZero       = block.timestamp;
    }

    function batchSettle(Receipt[] calldata receipts)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 settled, uint256 rejected)
    {
        uint256 len = receipts.length;
        if (len == 0) revert EmptyBatch();

        uint256 currentEpochNum = currentEpoch();
        for (uint256 i = 0; i < len; ++i) {
            (bool ok, bytes32 h) = _settleOne(receipts[i], currentEpochNum);
            if (ok) {
                ++settled;
            } else {
                ++rejected;
                h;
            }
        }
    }

    function _settleOne(Receipt calldata r, uint256 currentEpochNum)
        internal
        returns (bool ok, bytes32 h)
    {
        h = hashReceipt(r);

        if (_used[h]) {
            emit ReceiptRejected(h, r.capsuleId, "replay");
            return (false, h);
        }
        if (r.amountNox == 0) {
            emit ReceiptRejected(h, r.capsuleId, "zero-amount");
            return (false, h);
        }
        if (r.expiry != 0 && r.expiry < block.timestamp) {
            emit ReceiptRejected(h, r.capsuleId, "expired");
            return (false, h);
        }
        if (r.epoch != currentEpochNum && r.epoch + 1 != currentEpochNum) {
            emit ReceiptRejected(h, r.capsuleId, "wrong-epoch");
            return (false, h);
        }
        address signer = ECDSA.recover(_hashTypedDataV4(h), r.signature);
        if (signer != r.user) {
            emit ReceiptRejected(h, r.capsuleId, "wrong-signer");
            return (false, h);
        }
        if (capsuleRegistry.publisherOf(r.capsuleId) != r.publisher) {
            emit ReceiptRejected(h, r.capsuleId, "wrong-publisher");
            return (false, h);
        }

        _used[h] = true;

        IERC20 nox = IERC20(noxToken);
        nox.safeTransferFrom(r.user, address(this), r.amountNox);
        nox.forceApprove(address(feeRouter), r.amountNox);
        feeRouter.routeERC20(
            IFeeRouter.RevenueSource.PayPerUse,
            r.capsuleId,
            r.publisher,
            noxToken,
            r.amountNox
        );

        emit ReceiptSettled(h, r.capsuleId, r.user, r.publisher, r.amountNox, r.receiptType);
        return (true, h);
    }

    function hashReceipt(Receipt calldata r) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RECEIPT_TYPEHASH,
                r.capsuleId,
                r.user,
                r.publisher,
                r.amountNox,
                r.nonce,
                r.epoch,
                r.expiry,
                r.receiptType
            )
        );
    }

    function recoverSigner(Receipt calldata r) external view returns (address) {
        return ECDSA.recover(_hashTypedDataV4(hashReceipt(r)), r.signature);
    }

    function isUsed(bytes32 receiptHash) external view returns (bool) {
        return _used[receiptHash];
    }

    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < epochZero) return 0;
        return (block.timestamp - epochZero) / epochDuration;
    }

    function setEpochDuration(uint256 newDuration) external onlyRole(CONFIG_ROLE) {
        if (newDuration == 0) revert InvalidEpochDuration();
        emit EpochDurationUpdated(epochDuration, newDuration);
        epochDuration = newDuration;
    }

    function setNoxToken(address newToken) external onlyRole(CONFIG_ROLE) {
        if (newToken == address(0)) revert ZeroAddress();
        emit NoxTokenUpdated(noxToken, newToken);
        noxToken = newToken;
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
