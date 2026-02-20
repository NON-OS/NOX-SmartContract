// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPrivacyLiquidityPool } from "../interfaces/IPrivacyLiquidityPool.sol";

contract PrivacyLiquidityPool is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPrivacyLiquidityPool
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant FEE_ROUTER_ROLE = keccak256("FEE_ROUTER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant BOOTSTRAP_POOL = 40_000_000e18;
    uint256 public constant DISTRIBUTION_DAYS = 730;
    uint256 public constant DAILY_EMISSION = 54_794_520547945205479;

    struct PLPStorage {
        IERC20 noxToken;
        address rewardDistributor;
        address feeRouter;
        uint256 bootstrapDeposited;
        uint256 startTimestamp;
        uint256 totalDistributed;
        mapping(uint256 => uint256) epochFees;
        mapping(uint256 => bool) epochReleased;
    }

    bytes32 private constant STORAGE_LOCATION =
        0xb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb14eb100;

    function _getStorage() private pure returns (PLPStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address _noxToken,
        address _feeRouter,
        uint256 _startTimestamp
    ) external initializer {
        require(admin != address(0), "PLP: zero admin");
        require(_noxToken != address(0), "PLP: zero token");
        require(_feeRouter != address(0), "PLP: zero fee router");
        require(_startTimestamp > 0, "PLP: zero timestamp");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(FEE_ROUTER_ROLE, _feeRouter);

        PLPStorage storage $ = _getStorage();
        $.noxToken = IERC20(_noxToken);
        $.feeRouter = _feeRouter;
        $.startTimestamp = _startTimestamp;
    }

    function depositBootstrap(uint256 amount) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        require(amount > 0, "PLP: zero amount");

        PLPStorage storage $ = _getStorage();
        require($.bootstrapDeposited + amount <= BOOTSTRAP_POOL, "PLP: exceeds bootstrap");

        $.noxToken.safeTransferFrom(msg.sender, address(this), amount);
        $.bootstrapDeposited += amount;

        emit BootstrapDeposited(amount, block.timestamp);
    }

    function addFees(uint256 amount) external onlyRole(FEE_ROUTER_ROLE) whenNotPaused {
        require(amount > 0, "PLP: zero amount");

        PLPStorage storage $ = _getStorage();

        $.noxToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 currentEpoch = getCurrentEpoch();
        $.epochFees[currentEpoch] += amount;

        emit FeesAdded(currentEpoch, amount);
    }

    function releaseToDistributor(uint256 epoch) external onlyRole(DISTRIBUTOR_ROLE) nonReentrant returns (uint256 total) {
        PLPStorage storage $ = _getStorage();

        require(epoch > 0 && epoch < getCurrentEpoch(), "PLP: invalid epoch");
        require(!$.epochReleased[epoch], "PLP: already released");

        (,, uint256 epochTotal) = getEpochPool(epoch);
        require(epochTotal > 0, "PLP: nothing to release");

        uint256 balance = $.noxToken.balanceOf(address(this));
        require(balance >= epochTotal, "PLP: insufficient balance");

        $.epochReleased[epoch] = true;
        $.totalDistributed += epochTotal;

        $.noxToken.safeTransfer($.rewardDistributor, epochTotal);

        emit FundsReleased(epoch, epochTotal, $.rewardDistributor);

        return epochTotal;
    }

    function setRewardDistributor(address _rewardDistributor) external onlyRole(GOVERNOR_ROLE) {
        require(_rewardDistributor != address(0), "PLP: zero distributor");

        PLPStorage storage $ = _getStorage();
        $.rewardDistributor = _rewardDistributor;
        _grantRole(DISTRIBUTOR_ROLE, _rewardDistributor);
    }

    function setStartTimestamp(uint256 _startTimestamp) external onlyRole(GOVERNOR_ROLE) {
        PLPStorage storage $ = _getStorage();
        require(getCurrentEpoch() <= 1, "PLP: already started");
        require(_startTimestamp > 0, "PLP: zero timestamp");

        $.startTimestamp = _startTimestamp;
        emit StartTimestampSet(_startTimestamp);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function noxToken() external view returns (address) { return address(_getStorage().noxToken); }
    function rewardDistributor() external view returns (address) { return _getStorage().rewardDistributor; }
    function feeRouter() external view returns (address) { return _getStorage().feeRouter; }
    function bootstrapDeposited() external view returns (uint256) { return _getStorage().bootstrapDeposited; }
    function startTimestamp() external view returns (uint256) { return _getStorage().startTimestamp; }
    function totalDistributed() external view returns (uint256) { return _getStorage().totalDistributed; }
    function epochFees(uint256 epoch) external view returns (uint256) { return _getStorage().epochFees[epoch]; }
    function epochReleased(uint256 epoch) external view returns (bool) { return _getStorage().epochReleased[epoch]; }

    function getEpochEmission(uint256 epoch) public view returns (uint256 emission) {
        PLPStorage storage $ = _getStorage();

        if (epoch == 0) return 0;

        uint256 epochStartDay = (epoch - 1) * 7;
        uint256 epochEndDay = epoch * 7;

        if (epochStartDay >= DISTRIBUTION_DAYS) return 0;
        if (epochEndDay > DISTRIBUTION_DAYS) epochEndDay = DISTRIBUTION_DAYS;

        uint256 daysInEpoch = epochEndDay - epochStartDay;
        emission = DAILY_EMISSION * daysInEpoch;

        uint256 remaining = $.bootstrapDeposited > $.totalDistributed
            ? $.bootstrapDeposited - $.totalDistributed
            : 0;

        if (emission > remaining) emission = remaining;
        return emission;
    }

    function getEpochPool(uint256 epoch) public view returns (uint256 emissions, uint256 fees, uint256 total) {
        PLPStorage storage $ = _getStorage();
        emissions = getEpochEmission(epoch);
        fees = $.epochFees[epoch];
        total = emissions + fees;
    }

    function getCurrentEpoch() public view returns (uint256) {
        PLPStorage storage $ = _getStorage();
        if (block.timestamp < $.startTimestamp) return 0;
        return ((block.timestamp - $.startTimestamp) / EPOCH_DURATION) + 1;
    }

    function getEpochStartTime(uint256 epoch) public view returns (uint256) {
        PLPStorage storage $ = _getStorage();
        if (epoch == 0) return 0;
        return $.startTimestamp + ((epoch - 1) * EPOCH_DURATION);
    }

    function getEpochEndTime(uint256 epoch) public view returns (uint256) {
        PLPStorage storage $ = _getStorage();
        if (epoch == 0) return $.startTimestamp;
        return $.startTimestamp + (epoch * EPOCH_DURATION);
    }

    function getRemainingBootstrap() external view returns (uint256) {
        PLPStorage storage $ = _getStorage();
        return $.bootstrapDeposited > $.totalDistributed
            ? $.bootstrapDeposited - $.totalDistributed
            : 0;
    }

    function getBootstrapDaysRemaining() external view returns (uint256) {
        PLPStorage storage $ = _getStorage();
        uint256 daysPassed = (block.timestamp - $.startTimestamp) / 1 days;
        return daysPassed >= DISTRIBUTION_DAYS ? 0 : DISTRIBUTION_DAYS - daysPassed;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
