// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface ICapsuleRegistry {
    enum AppStatus { Draft, Listed, Revoked }
    enum ReleaseStatus { Uploaded, Validating, Validated, Failed, Published, Revoked, Superseded }

    struct App {
        bytes32 capsuleId;
        address publisher;
        bytes32 publisherKeyHash;
        string  metadataURI;
        AppStatus status;
        uint256 createdAt;
        uint256 latestPublishedReleaseIndex;
        uint256 releaseCount;
    }

    struct Release {
        bytes32 releaseId;
        bytes32 capsuleId;
        bytes32 manifestHash;
        bytes32 packageHash;
        bytes32 capabilityHash;
        string  packageFormatVersion;
        string  packageURI;
        string  validationReportURI;
        ReleaseStatus status;
        uint256 createdAt;
        uint256 publishedAt;
    }

    event AppRegistered(bytes32 indexed capsuleId, address indexed publisher, string metadataURI);
    event AppMetadataUpdated(bytes32 indexed capsuleId, string oldURI, string newURI);
    event AppRevoked(bytes32 indexed capsuleId, string reason);
    event ReleaseSubmitted(bytes32 indexed capsuleId, bytes32 indexed releaseId, bytes32 manifestHash, bytes32 packageHash);
    event ReleaseValidated(bytes32 indexed releaseId, address indexed validator, string reportURI);
    event ReleaseFailed(bytes32 indexed releaseId, address indexed validator, string reportURI);
    event ReleasePublished(bytes32 indexed releaseId, bytes32 indexed capsuleId);
    event ReleaseRevoked(bytes32 indexed releaseId, string reason);

    function registerApp(bytes32 capsuleId, bytes32 publisherKeyHash, string calldata metadataURI) external;
    function updateAppMetadata(bytes32 capsuleId, string calldata newURI) external;
    function revokeApp(bytes32 capsuleId, string calldata reason) external;

    function submitRelease(
        bytes32 capsuleId,
        bytes32 manifestHash,
        bytes32 packageHash,
        bytes32 capabilityHash,
        string calldata packageFormatVersion,
        string calldata packageURI
    ) external returns (bytes32 releaseId);

    function attachValidationResult(
        bytes32 releaseId,
        bool passed,
        string calldata reportURI
    ) external;

    function publishRelease(bytes32 releaseId) external;
    function revokeRelease(bytes32 releaseId, string calldata reason) external;

    function getApp(bytes32 capsuleId) external view returns (App memory);
    function getRelease(bytes32 releaseId) external view returns (Release memory);
    function getLatestPublishedRelease(bytes32 capsuleId) external view returns (Release memory);
    function isReleasePublished(bytes32 releaseId) external view returns (bool);
    function publisherOf(bytes32 capsuleId) external view returns (address);
    function appExists(bytes32 capsuleId) external view returns (bool);
}
