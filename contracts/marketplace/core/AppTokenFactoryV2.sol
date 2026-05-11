// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Clones}                     from "@openzeppelin/contracts/proxy/Clones.sol";

import {IAppTokenFactory}   from "../interfaces/IAppTokenFactory.sol";
import {IAppTokenFactoryV2} from "../interfaces/IAppTokenFactoryV2.sol";
import {ICapsuleRegistry}   from "../interfaces/ICapsuleRegistry.sol";
import {IAppBondingTokenV2} from "../interfaces/IAppBondingTokenV2.sol";
import {IFeeRouter}         from "../interfaces/IFeeRouter.sol";

contract AppTokenFactoryV2 is
    IAppTokenFactory,
    IAppTokenFactoryV2,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE   = keccak256("CONFIG_ROLE");

    uint16  public constant MAX_GRADUATION_FEE_BPS = 100;

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

    address public bondingTokenImplV2;
    bool    public launchEnabled;
    address public weth;
    address public uniV2Factory;
    address public uniV2Router;
    address public lpBurnTo;

    uint256[34] private __gap_v2;

    constructor() { _disableInitializers(); }

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
        _grantRole(UPGRADER_ROLE,      admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(CONFIG_ROLE,        admin);

        bondingTokenImpl = bondingTokenImpl_;
        capsuleRegistry  = capsuleRegistry_;
        feeRouter        = feeRouter_;
        launchFeeWei     = launchFeeWei_;
    }

    function initializeV2(
        address bondingTokenImplV2_,
        address weth_,
        address uniV2Factory_,
        address uniV2Router_,
        address lpBurnTo_
    ) external reinitializer(2) onlyRole(CONFIG_ROLE) {
        _setBondingTokenImplV2(bondingTokenImplV2_);
        _setUniswapInfra(weth_, uniV2Factory_, uniV2Router_, lpBurnTo_);
    }

    function createAppTokenV2(LaunchParamsV2 calldata p)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (address token)
    {
        if (!launchEnabled)                      revert LaunchDisabled();
        if (bondingTokenImplV2 == address(0))    revert InvalidImplementation();
        if (weth == address(0) || uniV2Factory == address(0) ||
            uniV2Router == address(0) || lpBurnTo == address(0)) revert UniswapInfraUnset();

        if (bytes(p.name).length == 0)           revert InvalidName();
        if (bytes(p.symbol).length == 0)         revert InvalidSymbol();
        if (p.graduationFeeBps > MAX_GRADUATION_FEE_BPS) {
            revert InvalidGraduationFee(MAX_GRADUATION_FEE_BPS, p.graduationFeeBps);
        }

        ICapsuleRegistry reg = ICapsuleRegistry(capsuleRegistry);
        if (!reg.appExists(p.capsuleId))                            revert CapsuleMissing();
        if (reg.publisherOf(p.capsuleId) != msg.sender)             revert NotPublisher();

        ICapsuleRegistry.Release memory rel = reg.getRelease(p.releaseId);
        if (rel.capsuleId != p.capsuleId)                           revert ReleaseMismatch();
        if (rel.status != ICapsuleRegistry.ReleaseStatus.Published) revert ReleaseNotPublished();

        if (_tokenForCapsule[p.capsuleId] != address(0))            revert AlreadyLaunched();
        if (msg.value < launchFeeWei)                               revert LaunchFeeRequired();

        token = Clones.clone(bondingTokenImplV2);

        IAppBondingTokenV2.AppLink memory link = IAppBondingTokenV2.AppLink({
            capsuleId:    p.capsuleId,
            releaseId:    p.releaseId,
            manifestHash: rel.manifestHash,
            packageHash:  rel.packageHash,
            publisher:    msg.sender
        });

        IAppBondingTokenV2.GraduationConfig memory cfg = IAppBondingTokenV2.GraduationConfig({
            graduationSupply: p.graduationSupply,
            lpReserveCap:     p.lpReserveCap,
            tradingFeeBps:    p.tradingFeeBps,
            graduationFeeBps: p.graduationFeeBps,
            weth:             weth,
            uniV2Factory:     uniV2Factory,
            uniV2Router:      uniV2Router,
            lpBurnTo:         lpBurnTo
        });

        IAppBondingTokenV2(token).initialize(
            link, feeRouter, p.name, p.symbol, p.metadataURI, cfg
        );

        _tokenForCapsule[p.capsuleId] = token;
        _capsuleForToken[token]       = p.capsuleId;
        _info[token] = TokenInfo({
            token:        token,
            capsuleId:    p.capsuleId,
            releaseId:    p.releaseId,
            manifestHash: rel.manifestHash,
            packageHash:  rel.packageHash,
            publisher:    msg.sender,
            launchedAt:   block.timestamp
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

        emit AppTokenCreatedV2(
            p.capsuleId, p.releaseId, msg.sender, token, p.name, p.symbol,
            p.graduationSupply, p.lpReserveCap
        );
        emit AppTokenCreated(p.capsuleId, p.releaseId, msg.sender, token, p.name, p.symbol);
    }

    function createAppToken(LaunchParams calldata) external payable returns (address) {
        revert LaunchDisabled();
    }

    function tokenForCapsule(bytes32 capsuleId)
        external view override(IAppTokenFactory, IAppTokenFactoryV2)
        returns (address)
    {
        return _tokenForCapsule[capsuleId];
    }
    function capsuleForToken(address token)
        external view override(IAppTokenFactory, IAppTokenFactoryV2)
        returns (bytes32)
    {
        return _capsuleForToken[token];
    }
    function getTokenInfo(address token) external view returns (TokenInfo memory) { return _info[token]; }
    function tokensByPublisher(address publisher) external view returns (address[] memory) { return _byPublisher[publisher]; }
    function tokenCount() external view returns (uint256) { return _allTokens.length; }

    function setBondingTokenImplV2(address newImpl) external onlyRole(CONFIG_ROLE) {
        _setBondingTokenImplV2(newImpl);
    }

    function setLaunchEnabled(bool enabled) external onlyRole(CONFIG_ROLE) {
        bool old = launchEnabled;
        launchEnabled = enabled;
        emit LaunchEnabledChanged(old, enabled, msg.sender);
    }

    function setUniswapInfra(address weth_, address uniV2Factory_, address uniV2Router_, address lpBurnTo_)
        external onlyRole(CONFIG_ROLE)
    {
        _setUniswapInfra(weth_, uniV2Factory_, uniV2Router_, lpBurnTo_);
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

    function pause()   external onlyRole(PAUSER_ROLE) { _pause();   }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _setBondingTokenImplV2(address newImpl) private {
        if (newImpl == address(0))         revert InvalidImplementation();
        emit BondingTokenImplV2Updated(bondingTokenImplV2, newImpl);
        bondingTokenImplV2 = newImpl;
    }

    function _setUniswapInfra(address w, address f, address r, address b) private {
        if (w == address(0) || f == address(0) || r == address(0) || b == address(0)) revert InvalidAddress();
        weth         = w;
        uniV2Factory = f;
        uniV2Router  = r;
        lpBurnTo     = b;
        emit UniswapInfraUpdated(w, f, r, b);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
