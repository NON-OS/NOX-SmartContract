// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFeeRouter}            from "../interfaces/IFeeRouter.sol";
import {IZeroStateRewardPool, IStakingRewards} from "../interfaces/IZeroStateRewardPool.sol";

contract FeeRouter is
    IFeeRouter,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE    = keccak256("CONFIG_ROLE");
    bytes32 public constant TREASURY_ROLE  = keccak256("TREASURY_ROLE");
    bytes32 public constant ROUTER_CALLER  = keccak256("ROUTER_CALLER");

    uint16 internal constant BPS_TOTAL = 10_000;

    address public nftHoldersSink;
    address public stakersSink;
    address public treasurySink;

    mapping(RevenueSource => SplitProfile) private _profile;
    mapping(bytes32 => mapping(address => uint256)) private _capsuleRevenue;
    mapping(address => mapping(address => uint256)) private _publisherRevenue;

    uint256[40] private __gap;

    error ZeroAddress();
    error InvalidProfile();
    error UnconfiguredSource();
    error TransferFailed();
    error PublisherZero();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address nftHoldersSink_,
        address stakersSink_,
        address treasurySink_
    ) external initializer {
        if (admin == address(0))            revert ZeroAddress();
        if (nftHoldersSink_ == address(0))  revert ZeroAddress();
        if (stakersSink_ == address(0))     revert ZeroAddress();
        if (treasurySink_ == address(0))    revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);

        nftHoldersSink = nftHoldersSink_;
        stakersSink    = stakersSink_;
        treasurySink   = treasurySink_;

        _profile[RevenueSource.AppPurchase]    = SplitProfile(7000, 1000, 1000, 1000, true);
        _profile[RevenueSource.Subscription]   = SplitProfile(7000, 1000, 1000, 1000, true);
        _profile[RevenueSource.PayPerUse]      = SplitProfile(7000, 1000, 1000, 1000, true);
        _profile[RevenueSource.TradingFee]     = SplitProfile( 500, 4000, 3500, 2000, true);
        _profile[RevenueSource.GraduationFee]  = SplitProfile(2500, 3000, 3000, 1500, true);
        _profile[RevenueSource.TokenLaunch]    = SplitProfile(   0, 4000, 3500, 2500, true);
        _profile[RevenueSource.ValidationFee]     = SplitProfile(   0, 4000, 3500, 2500, true);
    }

    function setSplitProfile(RevenueSource source, SplitProfile calldata p)
        external
        onlyRole(CONFIG_ROLE)
    {
        uint256 sum = uint256(p.publisherBps) + p.nftHoldersBps + p.stakersBps + p.treasuryBps;
        if (sum != BPS_TOTAL) revert InvalidProfile();
        SplitProfile memory profile = SplitProfile(
            p.publisherBps, p.nftHoldersBps, p.stakersBps, p.treasuryBps, true
        );
        _profile[source] = profile;
        emit SplitProfileUpdated(source, profile);
    }

    function setSinks(address newNftSink, address newStakersSink, address newTreasury)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (newNftSink != address(0) && newNftSink != nftHoldersSink) {
            emit SinkUpdated("nftHolders", nftHoldersSink, newNftSink);
            nftHoldersSink = newNftSink;
        }
        if (newStakersSink != address(0) && newStakersSink != stakersSink) {
            emit SinkUpdated("stakers", stakersSink, newStakersSink);
            stakersSink = newStakersSink;
        }
        if (newTreasury != address(0) && newTreasury != treasurySink) {
            emit SinkUpdated("treasury", treasurySink, newTreasury);
            treasurySink = newTreasury;
        }
    }

    function routeETH(
        RevenueSource source,
        bytes32 capsuleId,
        address publisher
    ) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) return;
        SplitProfile memory p = _profile[source];
        if (!p.configured) revert UnconfiguredSource();
        if (p.publisherBps > 0 && publisher == address(0)) revert PublisherZero();

        uint256 pubAmt = (msg.value * p.publisherBps)    / BPS_TOTAL;
        uint256 nftAmt = (msg.value * p.nftHoldersBps)   / BPS_TOTAL;
        uint256 stkAmt = (msg.value * p.stakersBps)      / BPS_TOTAL;
        uint256 trsAmt = msg.value - pubAmt - nftAmt - stkAmt;

        if (pubAmt > 0) _safeETH(publisher, pubAmt);
        if (nftAmt > 0) _safeETH(nftHoldersSink, nftAmt);
        if (stkAmt > 0) _safeETH(stakersSink, stkAmt);
        if (trsAmt > 0) _safeETH(treasurySink, trsAmt);

        _capsuleRevenue[capsuleId][address(0)]   += msg.value;
        _publisherRevenue[publisher][address(0)] += pubAmt;

        emit RevenueRouted(source, capsuleId, publisher, address(0), msg.value, pubAmt, nftAmt, stkAmt, trsAmt);
    }

    function routeERC20(
        RevenueSource source,
        bytes32 capsuleId,
        address publisher,
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        SplitProfile memory p = _profile[source];
        if (!p.configured) revert UnconfiguredSource();
        if (p.publisherBps > 0 && publisher == address(0)) revert PublisherZero();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 pubAmt = (amount * p.publisherBps)    / BPS_TOTAL;
        uint256 nftAmt = (amount * p.nftHoldersBps)   / BPS_TOTAL;
        uint256 stkAmt = (amount * p.stakersBps)      / BPS_TOTAL;
        uint256 trsAmt = amount - pubAmt - nftAmt - stkAmt;

        if (pubAmt > 0) IERC20(token).safeTransfer(publisher,       pubAmt);
        if (nftAmt > 0) IERC20(token).safeTransfer(nftHoldersSink,  nftAmt);
        if (stkAmt > 0) IERC20(token).safeTransfer(stakersSink,     stkAmt);
        if (trsAmt > 0) IERC20(token).safeTransfer(treasurySink,    trsAmt);

        _capsuleRevenue[capsuleId][token]   += amount;
        _publisherRevenue[publisher][token] += pubAmt;

        emit RevenueRouted(source, capsuleId, publisher, token, amount, pubAmt, nftAmt, stkAmt, trsAmt);
    }

    function getSplitProfile(RevenueSource source) external view returns (SplitProfile memory) {
        return _profile[source];
    }

    function capsuleRevenue(bytes32 capsuleId, address asset) external view returns (uint256) {
        return _capsuleRevenue[capsuleId][asset];
    }

    function publisherRevenue(address publisher, address asset) external view returns (uint256) {
        return _publisherRevenue[publisher][asset];
    }

    function emergencyWithdrawETH(address to, uint256 amount)
        external
        onlyRole(TREASURY_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        _safeETH(to, amount);
    }

    function emergencyWithdrawERC20(address token, address to, uint256 amount)
        external
        onlyRole(TREASURY_ROLE)
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _safeETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    receive() external payable {}
}
