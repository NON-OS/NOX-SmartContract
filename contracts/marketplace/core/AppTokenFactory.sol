// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Clones}                     from "@openzeppelin/contracts/proxy/Clones.sol";

import {IAppTokenFactory}  from "../interfaces/IAppTokenFactory.sol";
import {ICapsuleRegistry}  from "../interfaces/ICapsuleRegistry.sol";
import {IAppBondingToken}  from "../interfaces/IAppBondingToken.sol";
import {IFeeRouter}        from "../interfaces/IFeeRouter.sol";

contract AppTokenFactory is
    IAppTokenFactory,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE   = keccak256("CONFIG_ROLE");

    address public bondingTokenImpl;
    address public capsuleRegistry;
    address public feeRouter;
    uint256 public launchFeeWei;

    mapping(bytes32 => address) private _tokenForCapsule;
    mapping(address => bytes32) private _capsuleForToken;
    mapping(address => TokenInfo) private _info;
    mapping(address => address[]) private _byPublisher;
    address[] private _allTokens;

    uint256[40] private __gap;

    error InvalidAddress();
    error AlreadyLaunched();
    error CapsuleMissing();
    error ReleaseNotPublished();
    error NotPublisher();
    error LaunchFeeRequired();
    error InvalidName();
    error InvalidSymbol();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address bondingTokenImpl_,
        address capsuleRegistry_,
        address feeRouter_,
        uint256 launchFeeWei_
    ) external initializer {
        if (admin == address(0))             revert InvalidAddress();
        if (bondingTokenImpl_ == address(0)) revert InvalidAddress();
        if (capsuleRegistry_ == address(0))  revert InvalidAddress();
        if (feeRouter_ == address(0))        revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);

        bondingTokenImpl = bondingTokenImpl_;
        capsuleRegistry  = capsuleRegistry_;
        feeRouter        = feeRouter_;
        launchFeeWei     = launchFeeWei_;
    }

    function createAppToken(LaunchParams calldata p)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (address token)
    {
        if (bytes(p.name).length == 0)   revert InvalidName();
        if (bytes(p.symbol).length == 0) revert InvalidSymbol();

        ICapsuleRegistry reg = ICapsuleRegistry(capsuleRegistry);
        if (!reg.appExists(p.capsuleId)) revert CapsuleMissing();
        if (reg.publisherOf(p.capsuleId) != msg.sender) revert NotPublisher();

        ICapsuleRegistry.Release memory rel = reg.getRelease(p.releaseId);
        if (rel.capsuleId != p.capsuleId) revert ReleaseNotPublished();
        if (rel.status != ICapsuleRegistry.ReleaseStatus.Published) revert ReleaseNotPublished();

        if (_tokenForCapsule[p.capsuleId] != address(0)) revert AlreadyLaunched();

        if (msg.value < launchFeeWei) revert LaunchFeeRequired();

        token = Clones.clone(bondingTokenImpl);

        IAppBondingToken.AppLink memory link = IAppBondingToken.AppLink({
            capsuleId: p.capsuleId,
            releaseId: p.releaseId,
            manifestHash: rel.manifestHash,
            packageHash: rel.packageHash,
            publisher: msg.sender
        });

        IAppBondingToken(token).initialize(
            link,
            feeRouter,
            p.name,
            p.symbol,
            p.metadataURI,
            p.graduationSupply,
            p.feeBps
        );

        _tokenForCapsule[p.capsuleId] = token;
        _capsuleForToken[token] = p.capsuleId;
        _info[token] = TokenInfo({
            token: token,
            capsuleId: p.capsuleId,
            releaseId: p.releaseId,
            manifestHash: rel.manifestHash,
            packageHash: rel.packageHash,
            publisher: msg.sender,
            launchedAt: block.timestamp
        });
        _byPublisher[msg.sender].push(token);
        _allTokens.push(token);

        if (msg.value > 0) {
            IFeeRouter(feeRouter).routeETH{value: msg.value}(
                IFeeRouter.RevenueSource.TokenLaunch,
                p.capsuleId,
                msg.sender
            );
        }

        emit AppTokenCreated(p.capsuleId, p.releaseId, msg.sender, token, p.name, p.symbol);
    }

    function tokenForCapsule(bytes32 capsuleId) external view returns (address) {
        return _tokenForCapsule[capsuleId];
    }

    function capsuleForToken(address token) external view returns (bytes32) {
        return _capsuleForToken[token];
    }

    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return _info[token];
    }

    function tokensByPublisher(address publisher) external view returns (address[] memory) {
        return _byPublisher[publisher];
    }

    function tokenCount() external view returns (uint256) {
        return _allTokens.length;
    }

    function setBondingTokenImpl(address newImpl) external onlyRole(CONFIG_ROLE) {
        if (newImpl == address(0)) revert InvalidAddress();
        emit ImplementationUpdated(bondingTokenImpl, newImpl);
        bondingTokenImpl = newImpl;
    }

    function setCapsuleRegistry(address newRegistry) external onlyRole(CONFIG_ROLE) {
        if (newRegistry == address(0)) revert InvalidAddress();
        emit RegistryUpdated(capsuleRegistry, newRegistry);
        capsuleRegistry = newRegistry;
    }

    function setFeeRouter(address newRouter) external onlyRole(CONFIG_ROLE) {
        if (newRouter == address(0)) revert InvalidAddress();
        emit FeeRouterUpdated(feeRouter, newRouter);
        feeRouter = newRouter;
    }

    function setLaunchFee(uint256 newFee) external onlyRole(CONFIG_ROLE) {
        emit LaunchFeeUpdated(launchFeeWei, newFee);
        launchFeeWei = newFee;
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
