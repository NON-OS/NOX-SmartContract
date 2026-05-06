// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEntitlementRegistry} from "../interfaces/IEntitlementRegistry.sol";
import {ICapsuleRegistry}     from "../interfaces/ICapsuleRegistry.sol";
import {IAppTokenFactory}     from "../interfaces/IAppTokenFactory.sol";
import {IFeeRouter}           from "../interfaces/IFeeRouter.sol";

interface IERC721Minimal {
    function balanceOf(address owner) external view returns (uint256);
}

contract EntitlementRegistry is
    IEntitlementRegistry,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE   = keccak256("CONFIG_ROLE");

    ICapsuleRegistry public capsuleRegistry;
    IAppTokenFactory public appTokenFactory;
    IFeeRouter       public feeRouter;
    address          public noxToken;

    mapping(bytes32 => AccessConfig) private _configs;
    mapping(bytes32 => mapping(address => Entitlement)) private _entitlements;

    uint256[40] private __gap;

    error AppMissing();
    error NotPublisher();
    error InvalidConfig();
    error WrongMode();
    error AlreadyClaimed();
    error NotEnabled();
    error ZeroAddress();
    error PriceZero();
    error DurationZero();
    error GatingMissing();
    error TokenHolderNoToken();

    modifier onlyPublisherOrAdmin(bytes32 capsuleId) {
        if (
            capsuleRegistry.publisherOf(capsuleId) != msg.sender &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) revert NotPublisher();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address capsuleRegistry_,
        address appTokenFactory_,
        address feeRouter_,
        address noxToken_
    ) external initializer {
        if (admin == address(0))           revert ZeroAddress();
        if (capsuleRegistry_ == address(0)) revert ZeroAddress();
        if (appTokenFactory_ == address(0)) revert ZeroAddress();
        if (feeRouter_ == address(0))       revert ZeroAddress();
        if (noxToken_ == address(0))        revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);

        capsuleRegistry = ICapsuleRegistry(capsuleRegistry_);
        appTokenFactory = IAppTokenFactory(appTokenFactory_);
        feeRouter       = IFeeRouter(feeRouter_);
        noxToken        = noxToken_;
    }

    function configureEntitlement(bytes32 capsuleId, AccessConfig calldata params)
        external
        whenNotPaused
        onlyPublisherOrAdmin(capsuleId)
    {
        if (!capsuleRegistry.appExists(capsuleId)) revert AppMissing();
        _validateConfig(params);

        AccessConfig memory cfg = params;
        cfg.configured = true;
        _configs[capsuleId] = cfg;

        emit AccessConfigured(capsuleId, cfg.mode, cfg.gatingContract, cfg.priceNoxWei);
    }

    function _validateConfig(AccessConfig calldata p) internal pure {
        if (p.mode == AccessMode.Unconfigured || p.mode == AccessMode.Revoked) revert InvalidConfig();
        if (p.mode == AccessMode.OneTimeNOX || p.mode == AccessMode.Subscription) {
            if (p.priceNoxWei == 0) revert PriceZero();
        }
        if (p.mode == AccessMode.Subscription && p.subscriptionDuration == 0) revert DurationZero();
        if (p.mode == AccessMode.Trial && p.trialDuration == 0) revert DurationZero();
        if ((p.mode == AccessMode.TokenHolder || p.mode == AccessMode.NFTGated) && p.gatingContract == address(0)) revert GatingMissing();
    }

    function purchase(bytes32 capsuleId) external whenNotPaused nonReentrant {
        if (!capsuleRegistry.appExists(capsuleId)) revert AppMissing();
        AccessConfig memory cfg = _configs[capsuleId];
        if (!cfg.configured) revert NotEnabled();
        if (cfg.mode != AccessMode.OneTimeNOX && cfg.mode != AccessMode.Subscription) revert WrongMode();

        address publisher = capsuleRegistry.publisherOf(capsuleId);
        IERC20 nox = IERC20(noxToken);

        nox.safeTransferFrom(msg.sender, address(this), cfg.priceNoxWei);
        nox.forceApprove(address(feeRouter), cfg.priceNoxWei);
        feeRouter.routeERC20(
            cfg.mode == AccessMode.OneTimeNOX
                ? IFeeRouter.RevenueSource.AppPurchase
                : IFeeRouter.RevenueSource.Subscription,
            capsuleId,
            publisher,
            noxToken,
            cfg.priceNoxWei
        );

        Entitlement storage e = _entitlements[capsuleId][msg.sender];
        uint256 baseExpiry = e.expiresAt > block.timestamp ? e.expiresAt : block.timestamp;
        uint256 newExpiresAt = cfg.mode == AccessMode.Subscription
            ? baseExpiry + cfg.subscriptionDuration
            : 0;

        _entitlements[capsuleId][msg.sender] = Entitlement({
            mode: cfg.mode,
            capsuleId: capsuleId,
            releaseId: bytes32(0),
            user: msg.sender,
            publisher: publisher,
            paymentAsset: noxToken,
            expiresAt: newExpiresAt,
            grantedAt: block.timestamp,
            revoked: false
        });

        emit EntitlementPurchased(capsuleId, msg.sender, publisher, cfg.mode, newExpiresAt, cfg.priceNoxWei);
    }

    function claimTrial(bytes32 capsuleId) external whenNotPaused {
        if (!capsuleRegistry.appExists(capsuleId)) revert AppMissing();
        AccessConfig memory cfg = _configs[capsuleId];
        if (!cfg.configured || cfg.mode != AccessMode.Trial) revert WrongMode();
        if (_entitlements[capsuleId][msg.sender].grantedAt != 0) revert AlreadyClaimed();

        address publisher = capsuleRegistry.publisherOf(capsuleId);
        uint256 expires = block.timestamp + cfg.trialDuration;

        _entitlements[capsuleId][msg.sender] = Entitlement({
            mode: AccessMode.Trial,
            capsuleId: capsuleId,
            releaseId: bytes32(0),
            user: msg.sender,
            publisher: publisher,
            paymentAsset: address(0),
            expiresAt: expires,
            grantedAt: block.timestamp,
            revoked: false
        });
        emit TrialClaimed(capsuleId, msg.sender, expires);
    }

    function grantEntitlement(bytes32 capsuleId, address user, uint256 expiresAt)
        external
        whenNotPaused
        onlyPublisherOrAdmin(capsuleId)
    {
        if (!capsuleRegistry.appExists(capsuleId)) revert AppMissing();
        if (user == address(0)) revert ZeroAddress();

        address publisher = capsuleRegistry.publisherOf(capsuleId);

        _entitlements[capsuleId][user] = Entitlement({
            mode: AccessMode.PublisherGrant,
            capsuleId: capsuleId,
            releaseId: bytes32(0),
            user: user,
            publisher: publisher,
            paymentAsset: address(0),
            expiresAt: expiresAt,
            grantedAt: block.timestamp,
            revoked: false
        });
        emit EntitlementGranted(capsuleId, user, msg.sender, expiresAt);
    }

    function revokeEntitlement(bytes32 capsuleId, address user)
        external
        whenNotPaused
        onlyPublisherOrAdmin(capsuleId)
    {
        Entitlement storage e = _entitlements[capsuleId][user];
        e.mode = AccessMode.Revoked;
        e.revoked = true;
        emit EntitlementRevoked(capsuleId, user, msg.sender);
    }

    function hasEntitlement(bytes32 capsuleId, address user) public view returns (bool) {
        Entitlement memory e = _entitlements[capsuleId][user];
        if (e.revoked) return false;

        AccessConfig memory cfg = _configs[capsuleId];

        if (cfg.mode == AccessMode.Free) return true;

        if (cfg.mode == AccessMode.TokenHolder && cfg.gatingContract != address(0)) {
            return IERC20(cfg.gatingContract).balanceOf(user) >= cfg.gatingThreshold;
        }
        if (cfg.mode == AccessMode.NFTGated && cfg.gatingContract != address(0)) {
            uint256 thr = cfg.gatingThreshold == 0 ? 1 : cfg.gatingThreshold;
            return IERC721Minimal(cfg.gatingContract).balanceOf(user) >= thr;
        }

        if (e.grantedAt == 0) return false;
        if (e.expiresAt != 0 && e.expiresAt <= block.timestamp) return false;
        return true;
    }

    function entitlementOf(bytes32 capsuleId, address user) external view returns (Entitlement memory) {
        return _entitlements[capsuleId][user];
    }

    function configOf(bytes32 capsuleId) external view returns (AccessConfig memory) {
        return _configs[capsuleId];
    }

    function setNoxToken(address newToken) external onlyRole(CONFIG_ROLE) {
        if (newToken == address(0)) revert ZeroAddress();
        noxToken = newToken;
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
