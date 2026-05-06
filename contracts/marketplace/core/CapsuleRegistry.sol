// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}                from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable}     from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}          from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ICapsuleRegistry}             from "../interfaces/ICapsuleRegistry.sol";

contract CapsuleRegistry is
    ICapsuleRegistry,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    mapping(bytes32 => App) private _apps;
    mapping(bytes32 => Release) private _releases;
    mapping(bytes32 => bytes32[]) private _releaseIdsByCapsule;
    mapping(address => bytes32[]) private _capsulesByPublisher;

    uint256 public appCount;
    uint256 public releaseCount;

    uint256[40] private __gap;

    error AppExists();
    error AppMissing();
    error ReleaseMissing();
    error NotPublisher();
    error PublisherKeyHashZero();
    error MetadataURIEmpty();
    error PackageHashZero();
    error ManifestHashZero();
    error CapabilityHashZero();
    error PackageURIEmpty();
    error AppNotListed();
    error InvalidReleaseStatus();
    error AppRevokedErr();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert AppMissing();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(VALIDATOR_ROLE, admin);
    }

    function registerApp(
        bytes32 capsuleId,
        bytes32 publisherKeyHash,
        string calldata metadataURI
    ) external whenNotPaused {
        if (capsuleId == bytes32(0)) revert AppMissing();
        if (publisherKeyHash == bytes32(0)) revert PublisherKeyHashZero();
        if (bytes(metadataURI).length == 0) revert MetadataURIEmpty();
        if (_apps[capsuleId].publisher != address(0)) revert AppExists();

        _apps[capsuleId] = App({
            capsuleId: capsuleId,
            publisher: msg.sender,
            publisherKeyHash: publisherKeyHash,
            metadataURI: metadataURI,
            status: AppStatus.Draft,
            createdAt: block.timestamp,
            latestPublishedReleaseIndex: type(uint256).max,
            releaseCount: 0
        });
        _capsulesByPublisher[msg.sender].push(capsuleId);
        unchecked { appCount++; }

        emit AppRegistered(capsuleId, msg.sender, metadataURI);
    }

    function updateAppMetadata(bytes32 capsuleId, string calldata newURI) external whenNotPaused {
        App storage a = _apps[capsuleId];
        if (a.publisher == address(0)) revert AppMissing();
        if (a.publisher != msg.sender) revert NotPublisher();
        if (a.status == AppStatus.Revoked) revert AppRevokedErr();
        if (bytes(newURI).length == 0) revert MetadataURIEmpty();

        string memory oldURI = a.metadataURI;
        a.metadataURI = newURI;
        emit AppMetadataUpdated(capsuleId, oldURI, newURI);
    }

    function revokeApp(bytes32 capsuleId, string calldata reason)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        App storage a = _apps[capsuleId];
        if (a.publisher == address(0)) revert AppMissing();
        a.status = AppStatus.Revoked;
        emit AppRevoked(capsuleId, reason);
    }

    function submitRelease(
        bytes32 capsuleId,
        bytes32 manifestHash,
        bytes32 packageHash,
        bytes32 capabilityHash,
        string calldata packageFormatVersion,
        string calldata packageURI
    ) external whenNotPaused returns (bytes32 releaseId) {
        App storage a = _apps[capsuleId];
        if (a.publisher == address(0)) revert AppMissing();
        if (a.publisher != msg.sender) revert NotPublisher();
        if (a.status == AppStatus.Revoked) revert AppRevokedErr();
        if (manifestHash == bytes32(0)) revert ManifestHashZero();
        if (packageHash == bytes32(0)) revert PackageHashZero();
        if (capabilityHash == bytes32(0)) revert CapabilityHashZero();
        if (bytes(packageURI).length == 0) revert PackageURIEmpty();

        releaseId = keccak256(abi.encodePacked(capsuleId, manifestHash, packageHash, block.timestamp, releaseCount));

        _releases[releaseId] = Release({
            releaseId: releaseId,
            capsuleId: capsuleId,
            manifestHash: manifestHash,
            packageHash: packageHash,
            capabilityHash: capabilityHash,
            packageFormatVersion: packageFormatVersion,
            packageURI: packageURI,
            validationReportURI: "",
            status: ReleaseStatus.Uploaded,
            createdAt: block.timestamp,
            publishedAt: 0
        });

        _releaseIdsByCapsule[capsuleId].push(releaseId);
        unchecked {
            a.releaseCount++;
            releaseCount++;
        }

        emit ReleaseSubmitted(capsuleId, releaseId, manifestHash, packageHash);
    }

    function attachValidationResult(
        bytes32 releaseId,
        bool passed,
        string calldata reportURI
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused {
        Release storage r = _releases[releaseId];
        if (r.releaseId == bytes32(0)) revert ReleaseMissing();
        if (
            r.status != ReleaseStatus.Uploaded &&
            r.status != ReleaseStatus.Validating
        ) revert InvalidReleaseStatus();

        r.validationReportURI = reportURI;
        if (passed) {
            r.status = ReleaseStatus.Validated;
            emit ReleaseValidated(releaseId, msg.sender, reportURI);
        } else {
            r.status = ReleaseStatus.Failed;
            emit ReleaseFailed(releaseId, msg.sender, reportURI);
        }
    }

    function publishRelease(bytes32 releaseId) external whenNotPaused {
        Release storage r = _releases[releaseId];
        if (r.releaseId == bytes32(0)) revert ReleaseMissing();
        App storage a = _apps[r.capsuleId];
        if (a.publisher != msg.sender) revert NotPublisher();
        if (a.status == AppStatus.Revoked) revert AppRevokedErr();
        if (r.status != ReleaseStatus.Validated) revert InvalidReleaseStatus();

        r.status = ReleaseStatus.Published;
        r.publishedAt = block.timestamp;

        bytes32[] storage rels = _releaseIdsByCapsule[r.capsuleId];
        if (a.latestPublishedReleaseIndex != type(uint256).max) {
            bytes32 prev = rels[a.latestPublishedReleaseIndex];
            if (prev != releaseId && _releases[prev].status == ReleaseStatus.Published) {
                _releases[prev].status = ReleaseStatus.Superseded;
            }
        }

        for (uint256 i = 0; i < rels.length; i++) {
            if (rels[i] == releaseId) {
                a.latestPublishedReleaseIndex = i;
                break;
            }
        }
        if (a.status == AppStatus.Draft) {
            a.status = AppStatus.Listed;
        }

        emit ReleasePublished(releaseId, r.capsuleId);
    }

    function revokeRelease(bytes32 releaseId, string calldata reason)
        external
    {
        Release storage r = _releases[releaseId];
        if (r.releaseId == bytes32(0)) revert ReleaseMissing();
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            _apps[r.capsuleId].publisher != msg.sender
        ) revert NotPublisher();
        r.status = ReleaseStatus.Revoked;
        emit ReleaseRevoked(releaseId, reason);
    }

    function getApp(bytes32 capsuleId) external view returns (App memory) {
        App memory a = _apps[capsuleId];
        if (a.publisher == address(0)) revert AppMissing();
        return a;
    }

    function getRelease(bytes32 releaseId) external view returns (Release memory) {
        Release memory r = _releases[releaseId];
        if (r.releaseId == bytes32(0)) revert ReleaseMissing();
        return r;
    }

    function getLatestPublishedRelease(bytes32 capsuleId) external view returns (Release memory) {
        App memory a = _apps[capsuleId];
        if (a.publisher == address(0)) revert AppMissing();
        if (a.latestPublishedReleaseIndex == type(uint256).max) revert AppNotListed();
        bytes32 rid = _releaseIdsByCapsule[capsuleId][a.latestPublishedReleaseIndex];
        return _releases[rid];
    }

    function isReleasePublished(bytes32 releaseId) external view returns (bool) {
        return _releases[releaseId].status == ReleaseStatus.Published;
    }

    function publisherOf(bytes32 capsuleId) external view returns (address) {
        return _apps[capsuleId].publisher;
    }

    function appExists(bytes32 capsuleId) external view returns (bool) {
        return _apps[capsuleId].publisher != address(0);
    }

    function getReleaseIds(bytes32 capsuleId) external view returns (bytes32[] memory) {
        return _releaseIdsByCapsule[capsuleId];
    }

    function getCapsulesByPublisher(address publisher) external view returns (bytes32[] memory) {
        return _capsulesByPublisher[publisher];
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
