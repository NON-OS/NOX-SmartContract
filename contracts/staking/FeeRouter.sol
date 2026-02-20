// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFeeRouter } from "../interfaces/IFeeRouter.sol";
import { IPrivacyLiquidityPool } from "../interfaces/IPrivacyLiquidityPool.sol";

contract FeeRouter is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IFeeRouter
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    uint256 public constant EPOCH_DURATION = 7 days;

    struct FeeRouterStorage {
        IERC20 noxToken;
        address privacyLiquidityPool;
        uint256 startTimestamp;
        uint256 pendingFees;
        uint256 lastFlushEpoch;
        uint256 totalFeesCollected;
        mapping(address => bool) authorizedServices;
        mapping(address => uint256) serviceFeesCollected;
    }

    bytes32 private constant STORAGE_LOCATION = 0xfe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe4efe00;

    function _getStorage() private pure returns (FeeRouterStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(address admin, address _noxToken, uint256 _startTimestamp) external initializer {
        require(admin != address(0), "FR: zero admin");
        require(_noxToken != address(0), "FR: zero token");
        require(_startTimestamp > 0, "FR: zero timestamp");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        FeeRouterStorage storage $ = _getStorage();
        $.noxToken = IERC20(_noxToken);
        $.startTimestamp = _startTimestamp;
    }

    function collectFee(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "FR: zero amount");

        FeeRouterStorage storage $ = _getStorage();
        require($.authorizedServices[msg.sender], "FR: unauthorized");

        $.noxToken.safeTransferFrom(msg.sender, address(this), amount);

        $.pendingFees += amount;
        $.totalFeesCollected += amount;
        $.serviceFeesCollected[msg.sender] += amount;

        uint256 currentEpoch = getCurrentEpoch();
        emit FeeCollected(msg.sender, amount, currentEpoch);

        if ($.privacyLiquidityPool != address(0) && currentEpoch > $.lastFlushEpoch && $.pendingFees > 0) {
            _flush($);
        }
    }

    function flushToPLP() external nonReentrant whenNotPaused {
        FeeRouterStorage storage $ = _getStorage();
        require($.privacyLiquidityPool != address(0), "FR: PLP not set");
        require($.pendingFees > 0, "FR: no fees");
        _flush($);
    }

    function setPLP(address _plp) external onlyRole(GOVERNOR_ROLE) {
        require(_plp != address(0), "FR: zero PLP");
        _getStorage().privacyLiquidityPool = _plp;
        emit PLPUpdated(_plp);
    }

    function addAuthorizedService(address service) external onlyRole(GOVERNOR_ROLE) {
        require(service != address(0), "FR: zero address");
        FeeRouterStorage storage $ = _getStorage();
        require(!$.authorizedServices[service], "FR: already authorized");

        $.authorizedServices[service] = true;
        _grantRole(SERVICE_ROLE, service);
        emit ServiceAuthorized(service);
    }

    function removeAuthorizedService(address service) external onlyRole(GOVERNOR_ROLE) {
        FeeRouterStorage storage $ = _getStorage();
        require($.authorizedServices[service], "FR: not authorized");

        $.authorizedServices[service] = false;
        _revokeRole(SERVICE_ROLE, service);
        emit ServiceDeauthorized(service);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function _flush(FeeRouterStorage storage $) internal {
        uint256 amount = $.pendingFees;
        $.pendingFees = 0;
        $.lastFlushEpoch = getCurrentEpoch();

        $.noxToken.forceApprove($.privacyLiquidityPool, amount);
        IPrivacyLiquidityPool($.privacyLiquidityPool).addFees(amount);

        emit FeesFlushed($.lastFlushEpoch, amount);
    }

    function noxToken() external view returns (address) { return address(_getStorage().noxToken); }
    function privacyLiquidityPool() external view returns (address) { return _getStorage().privacyLiquidityPool; }
    function startTimestamp() external view returns (uint256) { return _getStorage().startTimestamp; }
    function pendingFees() external view returns (uint256) { return _getStorage().pendingFees; }
    function lastFlushEpoch() external view returns (uint256) { return _getStorage().lastFlushEpoch; }
    function authorizedServices(address service) external view returns (bool) { return _getStorage().authorizedServices[service]; }
    function serviceFeesCollected(address service) external view returns (uint256) { return _getStorage().serviceFeesCollected[service]; }
    function isAuthorizedService(address service) external view returns (bool) { return _getStorage().authorizedServices[service]; }

    function getCurrentEpoch() public view returns (uint256) {
        FeeRouterStorage storage $ = _getStorage();
        if (block.timestamp < $.startTimestamp) return 0;
        return ((block.timestamp - $.startTimestamp) / EPOCH_DURATION) + 1;
    }

    function getTotalFeesCollected() external view returns (uint256) { return _getStorage().totalFeesCollected; }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
