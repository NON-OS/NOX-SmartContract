// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILPStaking {
    enum LockTier {
        TIER_14D,
        TIER_30D,
        TIER_90D,
        TIER_180D,
        TIER_365D
    }

    struct TierConfig {
        uint256 duration;
        uint16 multiplierBps;
    }

    struct LockInfo {
        uint256 amount;
        uint256 effectiveAmount;
        uint256 lockedAt;
        uint256 unlockAt;
        LockTier tier;
        uint256 lastClaimEpoch;
    }

    event Locked(address indexed user, uint256 indexed lockId, uint256 amount, LockTier tier, uint256 unlockAt);
    event Unlocked(address indexed user, uint256 indexed lockId, uint256 amount);
    event EarlyUnlocked(address indexed user, uint256 indexed lockId, uint256 received, uint256 penalty);
    event LockExtended(address indexed user, uint256 indexed lockId, LockTier newTier, uint256 newUnlockAt);
    event RewardsClaimed(address indexed user, uint256 indexed lockId, uint256 amount);
    event RewardsCompounded(address indexed user, uint256 indexed lockId, uint256 amount);
    event PenaltyDistributed(uint256 toLPs, uint256 toTreasury);
    event EpochRewardsSet(uint256 indexed epoch, uint256 amount);
    event TreasuryUpdated(address indexed newTreasury);
    event RewardDistributorUpdated(address indexed newDistributor);

    function noxToken() external view returns (address);
    function treasury() external view returns (address);
    function rewardDistributor() external view returns (address);
    function startTimestamp() external view returns (uint256);
    function totalEffectiveStake() external view returns (uint256);
    function penaltyPool() external view returns (uint256);
    function lockOwners(uint256 lockId) external view returns (address);
    function locks(uint256 lockId) external view returns (
        uint256 amount, uint256 effectiveAmount, uint256 lockedAt,
        uint256 unlockAt, LockTier tier, uint256 lastClaimEpoch
    );

    function lock(uint256 amount, LockTier tier) external returns (uint256 lockId);
    function unlock(uint256 lockId) external;
    function earlyUnlock(uint256 lockId) external;
    function extendLock(uint256 lockId, LockTier newTier) external;
    function claimRewards(uint256 lockId) external;
    function claimAllRewards() external;
    function compoundRewards(uint256 lockId) external;

    function setEpochRewards(uint256 epoch, uint256 amount) external;
    function snapshotEpoch(uint256 epoch) external;

    function getLockInfo(address user, uint256 lockId) external view returns (LockInfo memory);
    function getUserLocks(address user) external view returns (uint256[] memory);
    function getUserLockCount(address user) external view returns (uint256);
    function getTierConfig(LockTier tier) external view returns (TierConfig memory);
    function getEarlyExitPenalty(uint256 lockId) external view returns (uint256 penaltyBps, uint256 penaltyAmount);
    function getPendingRewards(uint256 lockId) external view returns (uint256);
    function getTotalPendingRewards(address user) external view returns (uint256);
    function getCurrentEpoch() external view returns (uint256);
    function getEffectiveAmount(uint256 amount, LockTier tier) external view returns (uint256);
}
