// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IRewardDistributor } from "../interfaces/IRewardDistributor.sol";
import { IPrivacyLiquidityPool } from "../interfaces/IPrivacyLiquidityPool.sol";
import { IWorkRegistry } from "../interfaces/IWorkRegistry.sol";
import { ILPStaking } from "../interfaces/ILPStaking.sol";

contract RewardDistributor is
    Initializable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IRewardDistributor
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint16 public constant BPS = 10_000;
    uint256 public constant EPOCH_DURATION = 7 days;

    uint16 public constant NODE_SHARE_BPS = 7000;
    uint16 public constant LP_SHARE_BPS = 3000;

    uint256 public constant CLAIM_WINDOW_EPOCHS = 52;

    struct RewardDistributorStorage {
        IERC20 noxToken;
        address privacyLiquidityPool;
        address workRegistry;
        address collateralManager;
        address lpStaking;
        address treasury;
        uint256 startTimestamp;
        mapping(uint256 => EpochPool) epochPools;
        mapping(uint256 => mapping(address => bool)) nodeClaimedEpoch;
        mapping(uint256 => mapping(address => bool)) lpClaimedEpoch;
    }

    bytes32 private constant STORAGE_LOCATION =
        0xc24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec24ec200;

    function _getStorage() private pure returns (RewardDistributorStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address _noxToken,
        address _plp,
        address _workRegistry,
        address _collateralManager,
        address _lpStaking,
        address _treasury,
        uint256 _startTimestamp
    ) external initializer {
        require(admin != address(0), "RD: zero admin");
        require(_noxToken != address(0), "RD: zero token");
        require(_plp != address(0), "RD: zero PLP");
        require(_workRegistry != address(0), "RD: zero work registry");
        require(_collateralManager != address(0), "RD: zero collateral mgr");
        require(_lpStaking != address(0), "RD: zero LP staking");
        require(_treasury != address(0), "RD: zero treasury");
        require(_startTimestamp > 0, "RD: zero timestamp");

        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        RewardDistributorStorage storage $ = _getStorage();
        $.noxToken = IERC20(_noxToken);
        $.privacyLiquidityPool = _plp;
        $.workRegistry = _workRegistry;
        $.collateralManager = _collateralManager;
        $.lpStaking = _lpStaking;
        $.treasury = _treasury;
        $.startTimestamp = _startTimestamp;
    }

    function calculateEpochPools(uint256 epoch) external whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();

        require(epoch > 0 && epoch < getCurrentEpoch(), "RD: invalid epoch");
        require(!$.epochPools[epoch].calculated, "RD: already calculated");

        (,,, bool finalized) = IWorkRegistry($.workRegistry).epochData(epoch);
        require(finalized, "RD: epoch not finalized");

        uint256 total = IPrivacyLiquidityPool($.privacyLiquidityPool).releaseToDistributor(epoch);
        require(total > 0, "RD: no funds");

        uint256 nodePool = (total * NODE_SHARE_BPS) / BPS;
        uint256 lpPool = total - nodePool;

        $.epochPools[epoch] = EpochPool({
            nodePool: nodePool,
            lpPool: lpPool,
            nodeClaimed: 0,
            lpClaimed: 0,
            calculated: true
        });

        ILPStaking($.lpStaking).setEpochRewards(epoch, lpPool);
        ILPStaking($.lpStaking).snapshotEpoch(epoch);

        emit EpochPoolsCalculated(epoch, total, nodePool, lpPool);
    }

    function claimNodeReward(uint256 epoch) external nonReentrant whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();

        require($.epochPools[epoch].calculated, "RD: not calculated");
        require(!$.nodeClaimedEpoch[epoch][msg.sender], "RD: already claimed");
        require(isEpochClaimable(epoch), "RD: claim expired");

        uint256 reward = _calculateNodeReward($, epoch, msg.sender);
        require(reward > 0, "RD: no reward");

        $.nodeClaimedEpoch[epoch][msg.sender] = true;
        $.epochPools[epoch].nodeClaimed += reward;

        $.noxToken.safeTransfer(msg.sender, reward);

        emit NodeRewardClaimed(epoch, msg.sender, reward);
    }

    function claimLPReward(uint256 epoch) external nonReentrant whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();

        require($.epochPools[epoch].calculated, "RD: not calculated");
        require(!$.lpClaimedEpoch[epoch][msg.sender], "RD: already claimed");
        require(isEpochClaimable(epoch), "RD: claim expired");

        uint256 reward = _calculateLPReward($, epoch, msg.sender);
        require(reward > 0, "RD: no reward");

        $.lpClaimedEpoch[epoch][msg.sender] = true;
        $.epochPools[epoch].lpClaimed += reward;

        $.noxToken.safeTransfer(msg.sender, reward);

        emit LPRewardClaimed(epoch, msg.sender, reward);
    }

    function claimMultipleNodeRewards(uint256[] calldata epochs) external nonReentrant whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();
        uint256 totalReward = 0;

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];

            if (!$.epochPools[epoch].calculated) continue;
            if ($.nodeClaimedEpoch[epoch][msg.sender]) continue;
            if (!isEpochClaimable(epoch)) continue;

            uint256 reward = _calculateNodeReward($, epoch, msg.sender);
            if (reward > 0) {
                $.nodeClaimedEpoch[epoch][msg.sender] = true;
                $.epochPools[epoch].nodeClaimed += reward;
                totalReward += reward;
                emit NodeRewardClaimed(epoch, msg.sender, reward);
            }
        }

        require(totalReward > 0, "RD: nothing to claim");
        $.noxToken.safeTransfer(msg.sender, totalReward);
    }

    function claimMultipleLPRewards(uint256[] calldata epochs) external nonReentrant whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();
        uint256 totalReward = 0;

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];

            if (!$.epochPools[epoch].calculated) continue;
            if ($.lpClaimedEpoch[epoch][msg.sender]) continue;
            if (!isEpochClaimable(epoch)) continue;

            uint256 reward = _calculateLPReward($, epoch, msg.sender);
            if (reward > 0) {
                $.lpClaimedEpoch[epoch][msg.sender] = true;
                $.epochPools[epoch].lpClaimed += reward;
                totalReward += reward;
                emit LPRewardClaimed(epoch, msg.sender, reward);
            }
        }

        require(totalReward > 0, "RD: nothing to claim");
        $.noxToken.safeTransfer(msg.sender, totalReward);
    }

    function claimAllRewards(uint256[] calldata epochs) external nonReentrant whenNotPaused {
        RewardDistributorStorage storage $ = _getStorage();
        uint256 totalReward = 0;

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];

            if (!$.epochPools[epoch].calculated) continue;
            if (!isEpochClaimable(epoch)) continue;

            if (!$.nodeClaimedEpoch[epoch][msg.sender]) {
                uint256 nodeReward = _calculateNodeReward($, epoch, msg.sender);
                if (nodeReward > 0) {
                    $.nodeClaimedEpoch[epoch][msg.sender] = true;
                    $.epochPools[epoch].nodeClaimed += nodeReward;
                    totalReward += nodeReward;
                    emit NodeRewardClaimed(epoch, msg.sender, nodeReward);
                }
            }

            if (!$.lpClaimedEpoch[epoch][msg.sender]) {
                uint256 lpReward = _calculateLPReward($, epoch, msg.sender);
                if (lpReward > 0) {
                    $.lpClaimedEpoch[epoch][msg.sender] = true;
                    $.epochPools[epoch].lpClaimed += lpReward;
                    totalReward += lpReward;
                    emit LPRewardClaimed(epoch, msg.sender, lpReward);
                }
            }
        }

        require(totalReward > 0, "RD: nothing to claim");
        $.noxToken.safeTransfer(msg.sender, totalReward);
    }

    function sweepUnclaimed(uint256 epoch) external onlyRole(GOVERNOR_ROLE) {
        RewardDistributorStorage storage $ = _getStorage();

        require($.epochPools[epoch].calculated, "RD: not calculated");
        require(isEpochExpired(epoch), "RD: window open");

        EpochPool storage pool = $.epochPools[epoch];

        uint256 nodeUnclaimed = pool.nodePool - pool.nodeClaimed;
        uint256 lpUnclaimed = pool.lpPool - pool.lpClaimed;
        uint256 total = nodeUnclaimed + lpUnclaimed;

        if (total > 0) {
            pool.nodeClaimed = pool.nodePool;
            pool.lpClaimed = pool.lpPool;

            $.noxToken.safeTransfer($.treasury, total);
            emit UnclaimedSwept(epoch, nodeUnclaimed, lpUnclaimed);
        }
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        require(newTreasury != address(0), "RD: zero treasury");
        _getStorage().treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function _calculateNodeReward(
        RewardDistributorStorage storage $,
        uint256 epoch,
        address node
    ) internal view returns (uint256) {
        uint256 nodeWork = IWorkRegistry($.workRegistry).getWorkScore(epoch, node);
        if (nodeWork == 0) return 0;

        uint256 totalWork = IWorkRegistry($.workRegistry).getTotalWork(epoch);
        if (totalWork == 0) return 0;

        return ($.epochPools[epoch].nodePool * nodeWork) / totalWork;
    }

    function _calculateLPReward(
        RewardDistributorStorage storage $,
        uint256 epoch,
        address user
    ) internal view returns (uint256) {
        ILPStaking lpStakingContract = ILPStaking($.lpStaking);

        uint256[] memory lockIds = lpStakingContract.getUserLocks(user);
        if (lockIds.length == 0) return 0;

        uint256 userEffective = 0;
        uint256 epochEndTime = $.startTimestamp + (epoch * EPOCH_DURATION);

        for (uint256 i = 0; i < lockIds.length; i++) {
            (
                uint256 amount,
                uint256 effectiveAmount,
                uint256 lockedAt,
                ,
                ,

            ) = lpStakingContract.locks(lockIds[i]);

            if (amount > 0 && lockedAt <= epochEndTime) {
                userEffective += effectiveAmount;
            }
        }

        if (userEffective == 0) return 0;

        uint256 totalEffective = lpStakingContract.totalEffectiveStake();
        if (totalEffective == 0) return 0;

        return ($.epochPools[epoch].lpPool * userEffective) / totalEffective;
    }

    function noxToken() external view returns (address) { return address(_getStorage().noxToken); }
    function privacyLiquidityPool() external view returns (address) { return _getStorage().privacyLiquidityPool; }
    function workRegistry() external view returns (address) { return _getStorage().workRegistry; }
    function collateralManager() external view returns (address) { return _getStorage().collateralManager; }
    function lpStaking() external view returns (address) { return _getStorage().lpStaking; }
    function treasury() external view returns (address) { return _getStorage().treasury; }
    function startTimestamp() external view returns (uint256) { return _getStorage().startTimestamp; }

    function epochPools(uint256 epoch) external view returns (
        uint256 nodePool,
        uint256 lpPool,
        uint256 nodeClaimed,
        uint256 lpClaimed,
        bool calculated
    ) {
        EpochPool storage pool = _getStorage().epochPools[epoch];
        return (pool.nodePool, pool.lpPool, pool.nodeClaimed, pool.lpClaimed, pool.calculated);
    }

    function nodeClaimedEpoch(uint256 epoch, address node) external view returns (bool) {
        return _getStorage().nodeClaimedEpoch[epoch][node];
    }

    function lpClaimedEpoch(uint256 epoch, address user) external view returns (bool) {
        return _getStorage().lpClaimedEpoch[epoch][user];
    }

    function getClaimableNodeReward(uint256 epoch, address node) external view returns (uint256) {
        RewardDistributorStorage storage $ = _getStorage();
        if (!$.epochPools[epoch].calculated) return 0;
        if ($.nodeClaimedEpoch[epoch][node]) return 0;
        if (!isEpochClaimable(epoch)) return 0;
        return _calculateNodeReward($, epoch, node);
    }

    function getClaimableLPReward(uint256 epoch, address user) external view returns (uint256) {
        RewardDistributorStorage storage $ = _getStorage();
        if (!$.epochPools[epoch].calculated) return 0;
        if ($.lpClaimedEpoch[epoch][user]) return 0;
        if (!isEpochClaimable(epoch)) return 0;
        return _calculateLPReward($, epoch, user);
    }

    function getTotalClaimableNodeRewards(uint256[] calldata epochs, address node) external view returns (uint256) {
        RewardDistributorStorage storage $ = _getStorage();
        uint256 total = 0;

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];
            if ($.epochPools[epoch].calculated &&
                !$.nodeClaimedEpoch[epoch][node] &&
                isEpochClaimable(epoch))
            {
                total += _calculateNodeReward($, epoch, node);
            }
        }

        return total;
    }

    function getTotalClaimableLPRewards(uint256[] calldata epochs, address user) external view returns (uint256) {
        RewardDistributorStorage storage $ = _getStorage();
        uint256 total = 0;

        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];
            if ($.epochPools[epoch].calculated &&
                !$.lpClaimedEpoch[epoch][user] &&
                isEpochClaimable(epoch))
            {
                total += _calculateLPReward($, epoch, user);
            }
        }

        return total;
    }

    function getCurrentEpoch() public view returns (uint256) {
        RewardDistributorStorage storage $ = _getStorage();
        if (block.timestamp < $.startTimestamp) return 0;
        return ((block.timestamp - $.startTimestamp) / EPOCH_DURATION) + 1;
    }

    function isEpochClaimable(uint256 epoch) public view returns (bool) {
        uint256 current = getCurrentEpoch();
        if (epoch == 0 || epoch >= current) return false;
        return epoch + CLAIM_WINDOW_EPOCHS >= current;
    }

    function isEpochExpired(uint256 epoch) public view returns (bool) {
        uint256 current = getCurrentEpoch();
        if (epoch == 0) return true;
        return epoch + CLAIM_WINDOW_EPOCHS < current;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[50] private __gap;
}
