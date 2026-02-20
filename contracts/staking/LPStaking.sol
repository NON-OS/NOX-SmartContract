// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILPStaking } from "../interfaces/ILPStaking.sol";

contract LPStaking is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ILPStaking
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    uint16 public constant BPS = 10_000;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint16 public constant LP_PENALTY_SHARE_BPS = 8000;
    uint16 public constant TREASURY_PENALTY_SHARE_BPS = 2000;

    struct LPStakingStorage {
        IERC20 noxToken;
        address treasury;
        address rewardDistributor;
        uint256 startTimestamp;
        uint256 nextLockId;
        mapping(address => uint256[]) userLockIds;
        mapping(uint256 => address) lockOwners;
        mapping(uint256 => LockInfo) locks;
        uint256 totalEffectiveStake;
        uint256 penaltyPool;
        mapping(uint256 => uint256) epochRewards;
        mapping(uint256 => uint256) epochTotalEffective;
        TierConfig[5] tierConfigs;
        uint16[4] earlyExitPenalties;
    }

    bytes32 private constant STORAGE_LOCATION = 0x9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d4e9d00;

    function _getStorage() private pure returns (LPStakingStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(address admin, address _noxToken, address _treasury, uint256 _startTimestamp) external initializer {
        require(admin != address(0), "LPS: zero admin");
        require(_noxToken != address(0), "LPS: zero token");
        require(_treasury != address(0), "LPS: zero treasury");
        require(_startTimestamp > 0, "LPS: zero timestamp");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        LPStakingStorage storage $ = _getStorage();
        $.noxToken = IERC20(_noxToken);
        $.treasury = _treasury;
        $.startTimestamp = _startTimestamp;

        $.tierConfigs[0] = TierConfig(14 days, 10000);
        $.tierConfigs[1] = TierConfig(30 days, 12500);
        $.tierConfigs[2] = TierConfig(90 days, 16000);
        $.tierConfigs[3] = TierConfig(180 days, 20000);
        $.tierConfigs[4] = TierConfig(365 days, 25000);

        $.earlyExitPenalties[0] = 5000;
        $.earlyExitPenalties[1] = 3000;
        $.earlyExitPenalties[2] = 1500;
        $.earlyExitPenalties[3] = 500;
    }

    function lock(uint256 amount, LockTier tier) external nonReentrant whenNotPaused returns (uint256 lockId) {
        require(amount > 0, "LPS: zero amount");

        LPStakingStorage storage $ = _getStorage();
        $.noxToken.safeTransferFrom(msg.sender, address(this), amount);

        TierConfig storage config = $.tierConfigs[uint256(tier)];
        uint256 effectiveAmount = (amount * config.multiplierBps) / BPS;
        uint256 unlockAt = block.timestamp + config.duration;

        lockId = $.nextLockId++;
        $.locks[lockId] = LockInfo({
            amount: amount,
            effectiveAmount: effectiveAmount,
            lockedAt: block.timestamp,
            unlockAt: unlockAt,
            tier: tier,
            lastClaimEpoch: getCurrentEpoch()
        });

        $.lockOwners[lockId] = msg.sender;
        $.userLockIds[msg.sender].push(lockId);
        $.totalEffectiveStake += effectiveAmount;

        emit Locked(msg.sender, lockId, amount, tier, unlockAt);
    }

    function unlock(uint256 lockId) external nonReentrant {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == msg.sender, "LPS: not owner");

        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");
        require(block.timestamp >= info.unlockAt, "LPS: still locked");

        uint256 amount = info.amount;
        $.totalEffectiveStake -= info.effectiveAmount;
        _removeLock($, msg.sender, lockId);
        $.noxToken.safeTransfer(msg.sender, amount);

        emit Unlocked(msg.sender, lockId, amount);
    }

    function earlyUnlock(uint256 lockId) external nonReentrant {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == msg.sender, "LPS: not owner");

        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");
        require(block.timestamp < info.unlockAt, "LPS: use unlock()");

        (, uint256 penalty) = _calculatePenalty(info);
        uint256 amount = info.amount;
        uint256 received = amount - penalty;

        $.totalEffectiveStake -= info.effectiveAmount;

        uint256 toLPs = (penalty * LP_PENALTY_SHARE_BPS) / BPS;
        uint256 toTreasury = penalty - toLPs;

        $.penaltyPool += toLPs;
        _removeLock($, msg.sender, lockId);

        $.noxToken.safeTransfer(msg.sender, received);
        $.noxToken.safeTransfer($.treasury, toTreasury);

        emit EarlyUnlocked(msg.sender, lockId, received, penalty);
        emit PenaltyDistributed(toLPs, toTreasury);
    }

    function extendLock(uint256 lockId, LockTier newTier) external whenNotPaused {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == msg.sender, "LPS: not owner");

        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");
        require(uint256(newTier) > uint256(info.tier), "LPS: must increase tier");

        TierConfig storage newConfig = $.tierConfigs[uint256(newTier)];

        $.totalEffectiveStake -= info.effectiveAmount;
        info.effectiveAmount = (info.amount * newConfig.multiplierBps) / BPS;
        $.totalEffectiveStake += info.effectiveAmount;

        info.unlockAt = block.timestamp + newConfig.duration;
        info.tier = newTier;

        emit LockExtended(msg.sender, lockId, newTier, info.unlockAt);
    }

    function claimRewards(uint256 lockId) external nonReentrant {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == msg.sender, "LPS: not owner");

        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");

        uint256 rewards = _calculatePendingRewards($, lockId);
        require(rewards > 0, "LPS: no rewards");

        info.lastClaimEpoch = getCurrentEpoch() - 1;
        $.noxToken.safeTransfer(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, lockId, rewards);
    }

    function claimAllRewards() external nonReentrant {
        LPStakingStorage storage $ = _getStorage();
        uint256[] storage lockIds = $.userLockIds[msg.sender];
        require(lockIds.length > 0, "LPS: no locks");

        uint256 totalRewards = 0;
        for (uint256 i = 0; i < lockIds.length; i++) {
            uint256 lockId = lockIds[i];
            LockInfo storage info = $.locks[lockId];
            if (info.amount > 0) {
                uint256 rewards = _calculatePendingRewards($, lockId);
                if (rewards > 0) {
                    info.lastClaimEpoch = getCurrentEpoch() - 1;
                    totalRewards += rewards;
                    emit RewardsClaimed(msg.sender, lockId, rewards);
                }
            }
        }

        require(totalRewards > 0, "LPS: no rewards");
        $.noxToken.safeTransfer(msg.sender, totalRewards);
    }

    function compoundRewards(uint256 lockId) external nonReentrant whenNotPaused {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == msg.sender, "LPS: not owner");

        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");

        uint256 rewards = _calculatePendingRewards($, lockId);
        require(rewards > 0, "LPS: no rewards");

        info.lastClaimEpoch = getCurrentEpoch() - 1;

        $.totalEffectiveStake -= info.effectiveAmount;
        info.amount += rewards;
        info.effectiveAmount = (info.amount * $.tierConfigs[uint256(info.tier)].multiplierBps) / BPS;
        $.totalEffectiveStake += info.effectiveAmount;

        emit RewardsCompounded(msg.sender, lockId, rewards);
    }

    function setEpochRewards(uint256 epoch, uint256 amount) external onlyRole(DISTRIBUTOR_ROLE) {
        LPStakingStorage storage $ = _getStorage();
        $.epochRewards[epoch] = amount;
        emit EpochRewardsSet(epoch, amount);
    }

    function snapshotEpoch(uint256 epoch) external onlyRole(DISTRIBUTOR_ROLE) {
        LPStakingStorage storage $ = _getStorage();
        $.epochTotalEffective[epoch] = $.totalEffectiveStake;
    }

    function setRewardDistributor(address _rewardDistributor) external onlyRole(GOVERNOR_ROLE) {
        require(_rewardDistributor != address(0), "LPS: zero distributor");
        LPStakingStorage storage $ = _getStorage();
        $.rewardDistributor = _rewardDistributor;
        _grantRole(DISTRIBUTOR_ROLE, _rewardDistributor);
        emit RewardDistributorUpdated(_rewardDistributor);
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        require(newTreasury != address(0), "LPS: zero treasury");
        _getStorage().treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function _calculatePenalty(LockInfo storage info) internal view returns (uint16 penaltyBps, uint256 penaltyAmount) {
        LPStakingStorage storage $ = _getStorage();
        uint256 totalDuration = info.unlockAt - info.lockedAt;
        uint256 elapsed = block.timestamp - info.lockedAt;
        uint256 elapsedPct = (elapsed * 100) / totalDuration;

        if (elapsedPct < 25) { penaltyBps = $.earlyExitPenalties[0]; }
        else if (elapsedPct < 50) { penaltyBps = $.earlyExitPenalties[1]; }
        else if (elapsedPct < 75) { penaltyBps = $.earlyExitPenalties[2]; }
        else { penaltyBps = $.earlyExitPenalties[3]; }

        penaltyAmount = (info.amount * penaltyBps) / BPS;
    }

    function _calculatePendingRewards(LPStakingStorage storage $, uint256 lockId) internal view returns (uint256) {
        LockInfo storage info = $.locks[lockId];
        uint256 currentEpoch = getCurrentEpoch();
        uint256 pending = 0;

        for (uint256 e = info.lastClaimEpoch + 1; e < currentEpoch; e++) {
            uint256 epochTotal = $.epochTotalEffective[e];
            if (epochTotal > 0) {
                uint256 epochReward = $.epochRewards[e];
                pending += (epochReward * info.effectiveAmount) / epochTotal;
            }
        }

        if ($.totalEffectiveStake > 0 && $.penaltyPool > 0) {
            pending += ($.penaltyPool * info.effectiveAmount) / $.totalEffectiveStake;
        }

        return pending;
    }

    function _removeLock(LPStakingStorage storage $, address user, uint256 lockId) internal {
        delete $.locks[lockId];
        delete $.lockOwners[lockId];

        uint256[] storage userLocks = $.userLockIds[user];
        for (uint256 i = 0; i < userLocks.length; i++) {
            if (userLocks[i] == lockId) {
                userLocks[i] = userLocks[userLocks.length - 1];
                userLocks.pop();
                break;
            }
        }
    }

    function noxToken() external view returns (address) { return address(_getStorage().noxToken); }
    function treasury() external view returns (address) { return _getStorage().treasury; }
    function rewardDistributor() external view returns (address) { return _getStorage().rewardDistributor; }
    function startTimestamp() external view returns (uint256) { return _getStorage().startTimestamp; }
    function totalEffectiveStake() external view returns (uint256) { return _getStorage().totalEffectiveStake; }
    function penaltyPool() external view returns (uint256) { return _getStorage().penaltyPool; }
    function lockOwners(uint256 lockId) external view returns (address) { return _getStorage().lockOwners[lockId]; }

    function locks(uint256 lockId) external view returns (
        uint256 amount, uint256 effectiveAmount, uint256 lockedAt,
        uint256 unlockAt, LockTier tier, uint256 lastClaimEpoch
    ) {
        LockInfo storage info = _getStorage().locks[lockId];
        return (info.amount, info.effectiveAmount, info.lockedAt, info.unlockAt, info.tier, info.lastClaimEpoch);
    }

    function getLockInfo(address user, uint256 lockId) external view returns (LockInfo memory) {
        LPStakingStorage storage $ = _getStorage();
        require($.lockOwners[lockId] == user, "LPS: not owner");
        return $.locks[lockId];
    }

    function getUserLocks(address user) external view returns (uint256[] memory) { return _getStorage().userLockIds[user]; }
    function getUserLockCount(address user) external view returns (uint256) { return _getStorage().userLockIds[user].length; }
    function getTierConfig(LockTier tier) external view returns (TierConfig memory) { return _getStorage().tierConfigs[uint256(tier)]; }

    function getEarlyExitPenalty(uint256 lockId) external view returns (uint256 penaltyBps, uint256 penaltyAmount) {
        LPStakingStorage storage $ = _getStorage();
        LockInfo storage info = $.locks[lockId];
        require(info.amount > 0, "LPS: invalid lock");
        if (block.timestamp >= info.unlockAt) { return (0, 0); }
        return _calculatePenalty(info);
    }

    function getPendingRewards(uint256 lockId) external view returns (uint256) { return _calculatePendingRewards(_getStorage(), lockId); }

    function getTotalPendingRewards(address user) external view returns (uint256) {
        LPStakingStorage storage $ = _getStorage();
        uint256[] storage lockIds = $.userLockIds[user];
        uint256 total = 0;
        for (uint256 i = 0; i < lockIds.length; i++) {
            if ($.locks[lockIds[i]].amount > 0) {
                total += _calculatePendingRewards($, lockIds[i]);
            }
        }
        return total;
    }

    function getCurrentEpoch() public view returns (uint256) {
        LPStakingStorage storage $ = _getStorage();
        if (block.timestamp < $.startTimestamp) return 0;
        return ((block.timestamp - $.startTimestamp) / EPOCH_DURATION) + 1;
    }

    function getEffectiveAmount(uint256 amount, LockTier tier) external view returns (uint256) {
        return (amount * _getStorage().tierConfigs[uint256(tier)].multiplierBps) / BPS;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
