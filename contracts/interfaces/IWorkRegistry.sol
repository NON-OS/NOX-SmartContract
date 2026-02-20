// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWorkRegistry {
    struct WorkScore {
        uint256 traffic;
        uint256 zkProofs;
        uint256 mixerOps;
        uint256 entropy;
        uint256 registryOps;
    }

    struct EpochData {
        uint256 totalWork;
        uint256 nodeCount;
        uint256 submissionDeadline;
        bool finalized;
    }

    event WorkSubmitted(uint256 indexed epoch, address indexed node, uint256 score, address indexed oracle);
    event EpochFinalized(uint256 indexed epoch, uint256 totalWork, uint256 nodeCount);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);
    event CollateralManagerSet(address indexed collateralManager);

    function collateralManager() external view returns (address);
    function startTimestamp() external view returns (uint256);
    function finalScores(uint256 epoch, address node) external view returns (uint256);
    function epochData(uint256 epoch) external view returns (uint256 totalWork, uint256 nodeCount, uint256 submissionDeadline, bool finalized);

    function submitWorkBatch(uint256 epoch, address[] calldata nodes, WorkScore[] calldata scores) external;
    function finalizeEpoch(uint256 epoch) external;

    function getWorkScore(uint256 epoch, address node) external view returns (uint256);
    function getTotalWork(uint256 epoch) external view returns (uint256);
    function getNodeCount(uint256 epoch) external view returns (uint256);
    function getCurrentEpoch() external view returns (uint256);
    function getOracleSubmission(uint256 epoch, address node, address oracle) external view returns (WorkScore memory);
    function getOracleSubmissionCount(uint256 epoch, address node) external view returns (uint256);
}
