// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IEntitlementRegistry {
    enum AccessMode {
        Unconfigured,
        Free,
        OneTimeNOX,
        Subscription,
        TokenHolder,
        NFTGated,
        PublisherGrant,
        Trial,
        Revoked
    }

    struct AccessConfig {
        AccessMode mode;
        uint256 priceNoxWei;
        uint256 subscriptionDuration;
        address gatingContract;
        uint256 gatingThreshold;
        uint256 trialDuration;
        bool    configured;
    }

    struct Entitlement {
        AccessMode mode;
        bytes32 capsuleId;
        bytes32 releaseId;
        address user;
        address publisher;
        address paymentAsset;
        uint256 expiresAt;
        uint256 grantedAt;
        bool    revoked;
    }

    event AccessConfigured(bytes32 indexed capsuleId, AccessMode mode, address gatingContract, uint256 priceNoxWei);
    event EntitlementPurchased(bytes32 indexed capsuleId, address indexed user, address indexed publisher, AccessMode mode, uint256 expiresAt, uint256 priceNoxWei);
    event EntitlementGranted(bytes32 indexed capsuleId, address indexed user, address indexed grantedBy, uint256 expiresAt);
    event EntitlementRevoked(bytes32 indexed capsuleId, address indexed user, address indexed revokedBy);
    event TrialClaimed(bytes32 indexed capsuleId, address indexed user, uint256 expiresAt);

    function configureEntitlement(bytes32 capsuleId, AccessConfig calldata params) external;
    function purchase(bytes32 capsuleId) external;
    function claimTrial(bytes32 capsuleId) external;
    function grantEntitlement(bytes32 capsuleId, address user, uint256 expiresAt) external;
    function revokeEntitlement(bytes32 capsuleId, address user) external;

    function hasEntitlement(bytes32 capsuleId, address user) external view returns (bool);
    function entitlementOf(bytes32 capsuleId, address user) external view returns (Entitlement memory);
    function configOf(bytes32 capsuleId) external view returns (AccessConfig memory);
}
