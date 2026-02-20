// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralManager {
    enum SlashReason {
        FALSE_WORK,
        PRIVACY_VIOLATION,
        SYBIL_ATTACK,
        KEY_COMPROMISE
    }

    struct Stake {
        uint256 amount;
        uint256 stakedAt;
        bool isActive;
    }

    struct UnstakeRequest {
        uint256 amount;
        uint256 requestedAt;
        uint256 completableAt;
    }

    struct SlashProposal {
        address node;
        uint256 amount;
        SlashReason reason;
        address reporter;
        bytes32 evidenceHash;
        uint256 proposedAt;
        uint256 challengeDeadline;
        bool executed;
        bool challenged;
    }

    event Staked(address indexed node, uint256 amount, uint256 totalStake);
    event NodeRegistered(address indexed node, bytes publicKey);
    event NodeDeactivated(address indexed node);
    event UnstakeRequested(address indexed node, uint256 amount, uint256 completableAt);
    event UnstakeCancelled(address indexed node);
    event UnstakeCompleted(address indexed node, uint256 amount);
    event SlashProposed(uint256 indexed slashId, address indexed node, uint256 amount, SlashReason reason, address reporter);
    event SlashExecuted(uint256 indexed slashId, address indexed node, uint256 amount, uint256 reporterShare, uint256 treasuryShare);
    event SlashChallenged(uint256 indexed slashId, address indexed challenger);
    event TreasuryUpdated(address indexed newTreasury);

    function noxToken() external view returns (address);
    function treasury() external view returns (address);
    function stakes(address node) external view returns (uint256 amount, uint256 stakedAt, bool isActive);
    function nodePublicKeys(address node) external view returns (bytes memory);
    function unstakeRequests(address node) external view returns (uint256 amount, uint256 requestedAt, uint256 completableAt);
    function slashProposals(uint256 slashId) external view returns (
        address node, uint256 amount, SlashReason reason, address reporter,
        bytes32 evidenceHash, uint256 proposedAt, uint256 challengeDeadline, bool executed, bool challenged
    );
    function totalStaked() external view returns (uint256);
    function activeNodeCount() external view returns (uint256);
    function pendingSlashAmount(address node) external view returns (uint256);

    function stake(uint256 amount) external;
    function registerNode(bytes calldata publicKey) external;
    function deactivateNode() external;
    function requestUnstake(uint256 amount) external;
    function cancelUnstake() external;
    function completeUnstake() external;
    function proposeSlash(address node, SlashReason reason, bytes32 evidenceHash) external;
    function executeSlash(uint256 slashId) external;
    function challengeSlash(uint256 slashId, bytes calldata proof) external;

    function getMinCollateral() external view returns (uint256);
    function isActiveNode(address node) external view returns (bool);
    function isEligibleForRewards(address node) external view returns (bool);
    function getStake(address node) external view returns (uint256);
    function getSlashAmount(SlashReason reason, uint256 stakeAmount) external pure returns (uint256);
}
