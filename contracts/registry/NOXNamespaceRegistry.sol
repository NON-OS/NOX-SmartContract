// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 *  NOXNamespaceRegistry
 *  -----------------------------------------------------------------------
 *  Standalone, non-upgradeable contract that issues NONOS namespaces to
 *  staking positions that meet eligibility criteria.
 *
 *  Architecture rule (enforced by design):
 *      - This registry is purely ECOSYSTEM credentials. It records which
 *        wallet has reserved which name. It NEVER grants kernel capabilities
 *        and NEVER signs CapsuleManifest entries.
 *      - The NOX kernel does not read this registry for trust decisions.
 *
 *  Eligibility is delegated to the staking contract via
 *      staking.namespaceEligibility(wallet, positionId)
 *  which checks: active position, ≥ Silver-tier stake, validly bound ZSP.
 *
 *  Names are stored as keccak256 hashes so reservations are anonymous to
 *  on-chain observers until off-chain published.
 */

interface INOXStakingV4Eligibility {
    function namespaceEligibility(address wallet, uint256 positionId) external view returns (bool);
}

contract NOXNamespaceRegistry {
    INOXStakingV4Eligibility public immutable staking;

    struct Namespace {
        address owner;
        uint256 positionId;
        uint64 reservedAt;
    }

    mapping(bytes32 => Namespace) private _namespaces;

    event NamespaceReserved(bytes32 indexed nameHash, address indexed owner, uint256 indexed positionId);
    event NamespaceReleased(bytes32 indexed nameHash, address indexed owner);

    error NotEligible();
    error AlreadyReserved();
    error NotNamespaceOwner();
    error ZeroNameHash();

    constructor(address _staking) {
        staking = INOXStakingV4Eligibility(_staking);
    }

    function reserveNamespace(bytes32 nameHash, uint256 positionId) external {
        if (nameHash == bytes32(0)) revert ZeroNameHash();
        if (_namespaces[nameHash].owner != address(0)) revert AlreadyReserved();
        if (!staking.namespaceEligibility(msg.sender, positionId)) revert NotEligible();
        _namespaces[nameHash] = Namespace({owner: msg.sender, positionId: positionId, reservedAt: uint64(block.timestamp)});
        emit NamespaceReserved(nameHash, msg.sender, positionId);
    }

    function releaseNamespace(bytes32 nameHash) external {
        Namespace storage ns = _namespaces[nameHash];
        if (ns.owner != msg.sender) revert NotNamespaceOwner();
        delete _namespaces[nameHash];
        emit NamespaceReleased(nameHash, msg.sender);
    }

    function ownerOfNamespace(bytes32 nameHash) external view returns (address) {
        return _namespaces[nameHash].owner;
    }

    function getNamespace(bytes32 nameHash) external view returns (address owner, uint256 positionId, uint64 reservedAt) {
        Namespace storage ns = _namespaces[nameHash];
        return (ns.owner, ns.positionId, ns.reservedAt);
    }

    function canReserve(address wallet, uint256 positionId, bytes32 nameHash) external view returns (bool) {
        if (nameHash == bytes32(0)) return false;
        if (_namespaces[nameHash].owner != address(0)) return false;
        return staking.namespaceEligibility(wallet, positionId);
    }
}
