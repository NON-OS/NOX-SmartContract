// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardDistributor {
    struct EpochPool {
        uint256 nodePool;
        uint256 lpPool;
        uint256 nodeClaimed;
        uint256 lpClaimed;
        bool calculated;
    }

    event EpochPoolsCalculated(uint256 indexed epoch, uint256 total, uint256 nodePool, uint256 lpPool);
    event NodeRewardClaimed(uint256 indexed epoch, address indexed node, uint256 amount);
    event LPRewardClaimed(uint256 indexed epoch, address indexed user, uint256 amount);
    event UnclaimedSwept(uint256 indexed epoch, uint256 nodeUnclaimed, uint256 lpUnclaimed);
    event TreasuryUpdated(address indexed newTreasury);

    function noxToken() external view returns (address);
    function privacyLiquidityPool() external view returns (address);
    function workRegistry() external view returns (address);
    function collateralManager() external view returns (address);
    function lpStaking() external view returns (address);
    function treasury() external view returns (address);
    function startTimestamp() external view returns (uint256);
    function epochPools(uint256 epoch) external view returns (
        uint256 nodePool, uint256 lpPool, uint256 nodeClaimed, uint256 lpClaimed, bool calculated
    );
    function nodeClaimedEpoch(uint256 epoch, address node) external view returns (bool);
    function lpClaimedEpoch(uint256 epoch, address user) external view returns (bool);

    function calculateEpochPools(uint256 epoch) external;
    function claimNodeReward(uint256 epoch) external;
    function claimLPReward(uint256 epoch) external;
    function claimMultipleNodeRewards(uint256[] calldata epochs) external;
    function claimMultipleLPRewards(uint256[] calldata epochs) external;
    function claimAllRewards(uint256[] calldata epochs) external;
    function sweepUnclaimed(uint256 epoch) external;

    function getClaimableNodeReward(uint256 epoch, address node) external view returns (uint256);
    function getClaimableLPReward(uint256 epoch, address user) external view returns (uint256);
    function getTotalClaimableNodeRewards(uint256[] calldata epochs, address node) external view returns (uint256);
    function getTotalClaimableLPRewards(uint256[] calldata epochs, address user) external view returns (uint256);
    function getCurrentEpoch() external view returns (uint256);
    function isEpochClaimable(uint256 epoch) external view returns (bool);
    function isEpochExpired(uint256 epoch) external view returns (bool);
}
