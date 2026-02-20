// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPrivacyLiquidityPool {
    event BootstrapDeposited(uint256 amount, uint256 timestamp);
    event FeesAdded(uint256 indexed epoch, uint256 amount);
    event FundsReleased(uint256 indexed epoch, uint256 amount, address indexed distributor);
    event StartTimestampSet(uint256 timestamp);

    function noxToken() external view returns (address);
    function rewardDistributor() external view returns (address);
    function feeRouter() external view returns (address);
    function bootstrapDeposited() external view returns (uint256);
    function startTimestamp() external view returns (uint256);
    function totalDistributed() external view returns (uint256);
    function epochFees(uint256 epoch) external view returns (uint256);
    function epochReleased(uint256 epoch) external view returns (bool);

    function depositBootstrap(uint256 amount) external;
    function addFees(uint256 amount) external;
    function releaseToDistributor(uint256 epoch) external returns (uint256);

    function getEpochEmission(uint256 epoch) external view returns (uint256);
    function getEpochPool(uint256 epoch) external view returns (uint256 emissions, uint256 fees, uint256 total);
    function getCurrentEpoch() external view returns (uint256);
    function getEpochStartTime(uint256 epoch) external view returns (uint256);
    function getEpochEndTime(uint256 epoch) external view returns (uint256);
}
