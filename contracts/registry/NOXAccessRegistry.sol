// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/*
 *  NOXAccessRegistry
 *  -----------------------------------------------------------------------
 *  Standalone, non-upgradeable contract that records ecosystem access
 *  tiers for a wallet (or per-position). Used by the NONOS web app,
 *  noxctl CLI, and SDK docs portal to gate ECOSYSTEM features.
 *
 *  Architecture rule:
 *      - These flags are ECOSYSTEM CREDENTIALS only.
 *      - They never grant kernel capabilities.
 *      - The NONOS kernel does not consult this registry for trust.
 *      - CapsuleManifest remains the sole runtime-authority source.
 *
 *  Flags are bitfield-packed in a single uint256 per wallet, where each
 *  bit corresponds to a defined access tier. This makes off-chain
 *  introspection cheap and lets admins grant/revoke individual flags
 *  without touching the others.
 *
 *  Initial tiers (bit positions):
 *      0  BETA              — NONOS beta program access
 *      1  JONOS_PREVIEW     — jonos.software preview build
 *      2  SDK_DOCS          — private SDK documentation
 *      3  OPERATOR_WAITLIST — node operator queue
 *      4  CAPSULE_TOOLING   — capsule build/sign tooling
 *
 *  Bits 5-255 are reserved for future tiers.
 *
 *  ROLES:
 *      DEFAULT_ADMIN_ROLE — can grant/revoke ACCESS_ADMIN_ROLE
 *      ACCESS_ADMIN_ROLE  — can set/clear access flags for any wallet
 *
 *  The deployer (typically the 3-of-5 Safe) holds both roles initially.
 */

contract NOXAccessRegistry is AccessControl {
    bytes32 public constant ACCESS_ADMIN_ROLE = keccak256("ACCESS_ADMIN_ROLE");

    uint8 public constant FLAG_BETA = 0;
    uint8 public constant FLAG_JONOS_PREVIEW = 1;
    uint8 public constant FLAG_SDK_DOCS = 2;
    uint8 public constant FLAG_OPERATOR_WAITLIST = 3;
    uint8 public constant FLAG_CAPSULE_TOOLING = 4;

    mapping(address => uint256) private _flags;

    event AccessGranted(address indexed wallet, uint8 indexed flag);
    event AccessRevoked(address indexed wallet, uint8 indexed flag);
    event AccessBulkSet(address indexed wallet, uint256 oldMask, uint256 newMask);

    error InvalidFlag();
    error ZeroAddress();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ACCESS_ADMIN_ROLE, admin);
    }

    function grant(address wallet, uint8 flag) external onlyRole(ACCESS_ADMIN_ROLE) {
        if (wallet == address(0)) revert ZeroAddress();
        if (flag > 4) revert InvalidFlag();
        _flags[wallet] |= (uint256(1) << flag);
        emit AccessGranted(wallet, flag);
    }

    function revoke(address wallet, uint8 flag) external onlyRole(ACCESS_ADMIN_ROLE) {
        if (wallet == address(0)) revert ZeroAddress();
        if (flag > 4) revert InvalidFlag();
        _flags[wallet] &= ~(uint256(1) << flag);
        emit AccessRevoked(wallet, flag);
    }

    function setMask(address wallet, uint256 mask) external onlyRole(ACCESS_ADMIN_ROLE) {
        if (wallet == address(0)) revert ZeroAddress();
        uint256 old = _flags[wallet];
        _flags[wallet] = mask;
        emit AccessBulkSet(wallet, old, mask);
    }

    function hasAccess(address wallet, uint8 flag) external view returns (bool) {
        if (flag > 4) return false;
        return (_flags[wallet] & (uint256(1) << flag)) != 0;
    }

    function accessMask(address wallet) external view returns (uint256) {
        return _flags[wallet];
    }
}
