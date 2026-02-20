// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { IWorkRegistry } from "../interfaces/IWorkRegistry.sol";
import { ICollateralManager } from "../interfaces/ICollateralManager.sol";

contract WorkRegistry is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IWorkRegistry
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    uint16 public constant BPS = 10_000;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant SUBMISSION_WINDOW = 24 hours;
    uint256 public constant MIN_ORACLE_CONSENSUS = 3;

    uint16 public constant TRAFFIC_WEIGHT = 3000;
    uint16 public constant ZK_PROOF_WEIGHT = 2500;
    uint16 public constant MIXER_WEIGHT = 2000;
    uint16 public constant ENTROPY_WEIGHT = 1500;
    uint16 public constant REGISTRY_WEIGHT = 1000;

    uint256 public constant SCORE_CAP_MULTIPLIER = 5;

    struct WorkRegistryStorage {
        address collateralManager;
        uint256 startTimestamp;
        mapping(uint256 => mapping(address => uint256)) finalScores;
        mapping(uint256 => mapping(address => mapping(address => WorkScore))) oracleSubmissions;
        mapping(uint256 => mapping(address => address[])) nodeSubmitters;
        mapping(uint256 => mapping(address => mapping(address => bool))) hasSubmitted;
        mapping(uint256 => EpochData) epochData;
        mapping(uint256 => address[]) epochNodes;
        mapping(uint256 => mapping(address => bool)) epochNodeExists;
    }

    bytes32 private constant STORAGE_LOCATION = 0xad4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead4ead00;

    function _getStorage() private pure returns (WorkRegistryStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(address admin, address _collateralManager, uint256 _startTimestamp) external initializer {
        require(admin != address(0), "WR: zero admin");
        require(_collateralManager != address(0), "WR: zero collateral mgr");
        require(_startTimestamp > 0, "WR: zero timestamp");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        WorkRegistryStorage storage $ = _getStorage();
        $.collateralManager = _collateralManager;
        $.startTimestamp = _startTimestamp;
    }

    function submitWorkBatch(uint256 epoch, address[] calldata nodes, WorkScore[] calldata scores) external onlyRole(ORACLE_ROLE) whenNotPaused {
        require(nodes.length == scores.length, "WR: length mismatch");
        require(nodes.length > 0, "WR: empty batch");

        WorkRegistryStorage storage $ = _getStorage();

        require(epoch > 0 && epoch < getCurrentEpoch(), "WR: invalid epoch");
        require(!$.epochData[epoch].finalized, "WR: epoch finalized");

        uint256 epochEnd = $.startTimestamp + (epoch * EPOCH_DURATION);
        require(block.timestamp <= epochEnd + SUBMISSION_WINDOW, "WR: window closed");

        if ($.epochData[epoch].submissionDeadline == 0) {
            $.epochData[epoch].submissionDeadline = epochEnd + SUBMISSION_WINDOW;
        }

        ICollateralManager cm = ICollateralManager($.collateralManager);

        for (uint256 i = 0; i < nodes.length; i++) {
            address node = nodes[i];
            require(cm.getStake(node) > 0, "WR: node not staked");
            require(!$.hasSubmitted[epoch][node][msg.sender], "WR: already submitted");

            $.oracleSubmissions[epoch][node][msg.sender] = scores[i];
            $.hasSubmitted[epoch][node][msg.sender] = true;
            $.nodeSubmitters[epoch][node].push(msg.sender);

            if (!$.epochNodeExists[epoch][node]) {
                $.epochNodes[epoch].push(node);
                $.epochNodeExists[epoch][node] = true;
            }

            uint256 weightedScore = _computeWeightedScore(scores[i]);
            emit WorkSubmitted(epoch, node, weightedScore, msg.sender);
        }
    }

    function finalizeEpoch(uint256 epoch) external whenNotPaused {
        WorkRegistryStorage storage $ = _getStorage();

        require(epoch > 0 && epoch < getCurrentEpoch(), "WR: invalid epoch");
        require(!$.epochData[epoch].finalized, "WR: already finalized");

        uint256 epochEnd = $.startTimestamp + (epoch * EPOCH_DURATION);
        require(block.timestamp > epochEnd + SUBMISSION_WINDOW, "WR: window open");

        address[] storage nodes = $.epochNodes[epoch];
        uint256 totalWork = 0;
        uint256 validNodeCount = 0;

        uint256[] memory rawScores = new uint256[](nodes.length);

        for (uint256 i = 0; i < nodes.length; i++) {
            address node = nodes[i];
            address[] storage submitters = $.nodeSubmitters[epoch][node];

            if (submitters.length >= MIN_ORACLE_CONSENSUS) {
                rawScores[i] = _calculateConsensusScore($, epoch, node, submitters);
                if (rawScores[i] > 0) {
                    totalWork += rawScores[i];
                    validNodeCount++;
                }
            }
        }

        uint256 meanScore = validNodeCount > 0 ? totalWork / validNodeCount : 0;
        uint256 capScore = meanScore * SCORE_CAP_MULTIPLIER;

        totalWork = 0;
        for (uint256 i = 0; i < nodes.length; i++) {
            if (rawScores[i] > 0) {
                uint256 finalScore = rawScores[i] > capScore ? capScore : rawScores[i];
                $.finalScores[epoch][nodes[i]] = finalScore;
                totalWork += finalScore;
            }
        }

        $.epochData[epoch] = EpochData({
            totalWork: totalWork,
            nodeCount: validNodeCount,
            submissionDeadline: epochEnd + SUBMISSION_WINDOW,
            finalized: true
        });

        emit EpochFinalized(epoch, totalWork, validNodeCount);
    }

    function setCollateralManager(address _collateralManager) external onlyRole(GOVERNOR_ROLE) {
        require(_collateralManager != address(0), "WR: zero address");
        _getStorage().collateralManager = _collateralManager;
        emit CollateralManagerSet(_collateralManager);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function _calculateConsensusScore(WorkRegistryStorage storage $, uint256 epoch, address node, address[] storage submitters) internal view returns (uint256) {
        uint256 count = submitters.length;
        uint256[] memory scores = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            WorkScore storage ws = $.oracleSubmissions[epoch][node][submitters[i]];
            scores[i] = _computeWeightedScore(ws);
        }

        _sortArray(scores);
        return scores[count / 2];
    }

    function _computeWeightedScore(WorkScore memory ws) internal pure returns (uint256) {
        return ((ws.traffic * TRAFFIC_WEIGHT) + (ws.zkProofs * ZK_PROOF_WEIGHT) + (ws.mixerOps * MIXER_WEIGHT) + (ws.entropy * ENTROPY_WEIGHT) + (ws.registryOps * REGISTRY_WEIGHT)) / BPS;
    }

    function _sortArray(uint256[] memory arr) internal pure {
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    function collateralManager() external view returns (address) { return _getStorage().collateralManager; }
    function startTimestamp() external view returns (uint256) { return _getStorage().startTimestamp; }
    function finalScores(uint256 epoch, address node) external view returns (uint256) { return _getStorage().finalScores[epoch][node]; }

    function epochData(uint256 epoch) external view returns (uint256 totalWork, uint256 nodeCount, uint256 submissionDeadline, bool finalized) {
        EpochData storage data = _getStorage().epochData[epoch];
        return (data.totalWork, data.nodeCount, data.submissionDeadline, data.finalized);
    }

    function getWorkScore(uint256 epoch, address node) external view returns (uint256) { return _getStorage().finalScores[epoch][node]; }
    function getTotalWork(uint256 epoch) external view returns (uint256) { return _getStorage().epochData[epoch].totalWork; }
    function getNodeCount(uint256 epoch) external view returns (uint256) { return _getStorage().epochData[epoch].nodeCount; }

    function getCurrentEpoch() public view returns (uint256) {
        WorkRegistryStorage storage $ = _getStorage();
        if (block.timestamp < $.startTimestamp) return 0;
        return ((block.timestamp - $.startTimestamp) / EPOCH_DURATION) + 1;
    }

    function getOracleSubmission(uint256 epoch, address node, address oracle) external view returns (WorkScore memory) {
        return _getStorage().oracleSubmissions[epoch][node][oracle];
    }

    function getOracleSubmissionCount(uint256 epoch, address node) external view returns (uint256) {
        return _getStorage().nodeSubmitters[epoch][node].length;
    }

    function getEpochNodes(uint256 epoch) external view returns (address[] memory) { return _getStorage().epochNodes[epoch]; }
    function isEpochFinalized(uint256 epoch) external view returns (bool) { return _getStorage().epochData[epoch].finalized; }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
