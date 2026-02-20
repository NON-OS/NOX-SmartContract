// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICollateralManager } from "../interfaces/ICollateralManager.sol";

contract CollateralManager is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ICollateralManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    uint16 public constant BPS = 10_000;
    uint256 public constant BASE_MIN_COLLATERAL = 10_000e18;
    uint256 public constant UNSTAKE_DELAY = 14 days;
    uint256 public constant SLASH_CHALLENGE_PERIOD = 7 days;

    uint16 public constant SLASH_FALSE_WORK_BPS = 500;
    uint16 public constant SLASH_PRIVACY_VIOLATION_BPS = 1000;
    uint16 public constant SLASH_SYBIL_ATTACK_BPS = 2500;
    uint16 public constant SLASH_KEY_COMPROMISE_BPS = 10000;

    uint16 public constant REPORTER_SHARE_BPS = 5000;
    uint16 public constant TREASURY_SHARE_BPS = 5000;

    struct CollateralManagerStorage {
        IERC20 noxToken;
        address treasury;
        mapping(address => Stake) stakes;
        mapping(address => bytes) nodePublicKeys;
        mapping(address => UnstakeRequest) unstakeRequests;
        uint256 totalStaked;
        uint256 activeNodeCount;
        uint256 nextSlashId;
        mapping(uint256 => SlashProposal) slashProposals;
        mapping(address => uint256) pendingSlashAmount;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x8c4e8d8c8e8d8c8e8d8c8e8d8c8e8d8c8e8d8c8e8d8c8e8d8c8e8d8c8e8d8c00;

    function _getStorage() private pure returns (CollateralManagerStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(address admin, address _noxToken, address _treasury) external initializer {
        require(admin != address(0), "CM: zero admin");
        require(_noxToken != address(0), "CM: zero token");
        require(_treasury != address(0), "CM: zero treasury");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        CollateralManagerStorage storage $ = _getStorage();
        $.noxToken = IERC20(_noxToken);
        $.treasury = _treasury;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "CM: zero amount");

        CollateralManagerStorage storage $ = _getStorage();
        $.noxToken.safeTransferFrom(msg.sender, address(this), amount);

        Stake storage s = $.stakes[msg.sender];
        s.amount += amount;
        if (s.stakedAt == 0) { s.stakedAt = block.timestamp; }
        $.totalStaked += amount;

        emit Staked(msg.sender, amount, s.amount);
    }

    function registerNode(bytes calldata publicKey) external whenNotPaused {
        require(publicKey.length == 33 || publicKey.length == 65, "CM: invalid pubkey");

        CollateralManagerStorage storage $ = _getStorage();
        Stake storage s = $.stakes[msg.sender];

        require(s.amount >= getMinCollateral(), "CM: insufficient stake");
        require(!s.isActive, "CM: already active");

        s.isActive = true;
        $.nodePublicKeys[msg.sender] = publicKey;
        $.activeNodeCount++;

        emit NodeRegistered(msg.sender, publicKey);
    }

    function deactivateNode() external {
        CollateralManagerStorage storage $ = _getStorage();
        Stake storage s = $.stakes[msg.sender];
        require(s.isActive, "CM: not active");

        s.isActive = false;
        $.activeNodeCount--;

        emit NodeDeactivated(msg.sender);
    }

    function requestUnstake(uint256 amount) external whenNotPaused {
        require(amount > 0, "CM: zero amount");

        CollateralManagerStorage storage $ = _getStorage();
        Stake storage s = $.stakes[msg.sender];

        require(amount <= s.amount, "CM: exceeds stake");
        require($.unstakeRequests[msg.sender].amount == 0, "CM: pending request");
        require($.pendingSlashAmount[msg.sender] == 0, "CM: pending slash");

        if (s.isActive) {
            uint256 remaining = s.amount - amount;
            if (remaining > 0) {
                require(remaining >= getMinCollateral(), "CM: below minimum");
            } else {
                s.isActive = false;
                $.activeNodeCount--;
                emit NodeDeactivated(msg.sender);
            }
        }

        uint256 completableAt = block.timestamp + UNSTAKE_DELAY;
        $.unstakeRequests[msg.sender] = UnstakeRequest({
            amount: amount,
            requestedAt: block.timestamp,
            completableAt: completableAt
        });

        emit UnstakeRequested(msg.sender, amount, completableAt);
    }

    function cancelUnstake() external {
        CollateralManagerStorage storage $ = _getStorage();
        require($.unstakeRequests[msg.sender].amount > 0, "CM: no request");
        delete $.unstakeRequests[msg.sender];
        emit UnstakeCancelled(msg.sender);
    }

    function completeUnstake() external nonReentrant {
        CollateralManagerStorage storage $ = _getStorage();
        UnstakeRequest storage req = $.unstakeRequests[msg.sender];

        require(req.amount > 0, "CM: no request");
        require(block.timestamp >= req.completableAt, "CM: delay not passed");
        require($.pendingSlashAmount[msg.sender] == 0, "CM: pending slash");

        uint256 amount = req.amount;
        $.stakes[msg.sender].amount -= amount;
        $.totalStaked -= amount;
        delete $.unstakeRequests[msg.sender];

        $.noxToken.safeTransfer(msg.sender, amount);

        emit UnstakeCompleted(msg.sender, amount);
    }

    function proposeSlash(address node, SlashReason reason, bytes32 evidenceHash) external onlyRole(SLASHER_ROLE) whenNotPaused {
        CollateralManagerStorage storage $ = _getStorage();
        Stake storage s = $.stakes[node];

        require(s.isActive || s.amount > 0, "CM: no stake");

        uint256 slashAmount = getSlashAmount(reason, s.amount);
        require(slashAmount <= s.amount - $.pendingSlashAmount[node], "CM: exceeds available");

        uint256 slashId = $.nextSlashId++;
        $.slashProposals[slashId] = SlashProposal({
            node: node,
            amount: slashAmount,
            reason: reason,
            reporter: msg.sender,
            evidenceHash: evidenceHash,
            proposedAt: block.timestamp,
            challengeDeadline: block.timestamp + SLASH_CHALLENGE_PERIOD,
            executed: false,
            challenged: false
        });

        $.pendingSlashAmount[node] += slashAmount;

        emit SlashProposed(slashId, node, slashAmount, reason, msg.sender);
    }

    function executeSlash(uint256 slashId) external nonReentrant {
        CollateralManagerStorage storage $ = _getStorage();
        SlashProposal storage proposal = $.slashProposals[slashId];

        require(proposal.amount > 0, "CM: invalid slash");
        require(!proposal.executed, "CM: already executed");
        require(!proposal.challenged, "CM: was challenged");
        require(block.timestamp > proposal.challengeDeadline, "CM: challenge period");

        proposal.executed = true;

        address node = proposal.node;
        uint256 amount = proposal.amount;

        $.stakes[node].amount -= amount;
        $.totalStaked -= amount;
        $.pendingSlashAmount[node] -= amount;

        if ($.stakes[node].isActive && $.stakes[node].amount < getMinCollateral()) {
            $.stakes[node].isActive = false;
            $.activeNodeCount--;
            emit NodeDeactivated(node);
        }

        uint256 reporterShare = (amount * REPORTER_SHARE_BPS) / BPS;
        uint256 treasuryShare = amount - reporterShare;

        $.noxToken.safeTransfer(proposal.reporter, reporterShare);
        $.noxToken.safeTransfer($.treasury, treasuryShare);

        emit SlashExecuted(slashId, node, amount, reporterShare, treasuryShare);
    }

    function challengeSlash(uint256 slashId, bytes calldata proof) external {
        CollateralManagerStorage storage $ = _getStorage();
        SlashProposal storage proposal = $.slashProposals[slashId];

        require(proposal.amount > 0, "CM: invalid slash");
        require(!proposal.executed, "CM: already executed");
        require(!proposal.challenged, "CM: already challenged");
        require(block.timestamp <= proposal.challengeDeadline, "CM: challenge expired");
        require(msg.sender == proposal.node, "CM: not node owner");
        require(proof.length > 0, "CM: empty proof");

        proposal.challenged = true;
        $.pendingSlashAmount[proposal.node] -= proposal.amount;

        emit SlashChallenged(slashId, msg.sender);
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        require(newTreasury != address(0), "CM: zero treasury");
        _getStorage().treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function noxToken() external view returns (address) { return address(_getStorage().noxToken); }
    function treasury() external view returns (address) { return _getStorage().treasury; }

    function stakes(address node) external view returns (uint256 amount, uint256 stakedAt, bool isActive) {
        Stake storage s = _getStorage().stakes[node];
        return (s.amount, s.stakedAt, s.isActive);
    }

    function nodePublicKeys(address node) external view returns (bytes memory) { return _getStorage().nodePublicKeys[node]; }

    function unstakeRequests(address node) external view returns (uint256 amount, uint256 requestedAt, uint256 completableAt) {
        UnstakeRequest storage req = _getStorage().unstakeRequests[node];
        return (req.amount, req.requestedAt, req.completableAt);
    }

    function slashProposals(uint256 slashId) external view returns (
        address node, uint256 amount, SlashReason reason, address reporter,
        bytes32 evidenceHash, uint256 proposedAt, uint256 challengeDeadline, bool executed, bool challenged
    ) {
        SlashProposal storage p = _getStorage().slashProposals[slashId];
        return (p.node, p.amount, p.reason, p.reporter, p.evidenceHash, p.proposedAt, p.challengeDeadline, p.executed, p.challenged);
    }

    function totalStaked() external view returns (uint256) { return _getStorage().totalStaked; }
    function activeNodeCount() external view returns (uint256) { return _getStorage().activeNodeCount; }
    function pendingSlashAmount(address node) external view returns (uint256) { return _getStorage().pendingSlashAmount[node]; }

    function getMinCollateral() public view returns (uint256) {
        uint256 nodes = _getStorage().activeNodeCount;
        if (nodes <= 10) { return BASE_MIN_COLLATERAL; }
        uint256 scaled = (nodes * 1e18) / 10;
        uint256 sqrtScaled = Math.sqrt(scaled);
        return (BASE_MIN_COLLATERAL * sqrtScaled) / 1e9;
    }

    function isActiveNode(address node) external view returns (bool) { return _getStorage().stakes[node].isActive; }

    function isEligibleForRewards(address node) external view returns (bool) {
        CollateralManagerStorage storage $ = _getStorage();
        Stake storage s = $.stakes[node];
        return s.isActive && s.amount >= getMinCollateral() && $.pendingSlashAmount[node] == 0;
    }

    function getStake(address node) external view returns (uint256) { return _getStorage().stakes[node].amount; }

    function getSlashAmount(SlashReason reason, uint256 stakeAmount) public pure returns (uint256) {
        uint16 slashBps;
        if (reason == SlashReason.FALSE_WORK) { slashBps = SLASH_FALSE_WORK_BPS; }
        else if (reason == SlashReason.PRIVACY_VIOLATION) { slashBps = SLASH_PRIVACY_VIOLATION_BPS; }
        else if (reason == SlashReason.SYBIL_ATTACK) { slashBps = SLASH_SYBIL_ATTACK_BPS; }
        else { slashBps = SLASH_KEY_COMPROMISE_BPS; }
        return (stakeAmount * slashBps) / BPS;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
