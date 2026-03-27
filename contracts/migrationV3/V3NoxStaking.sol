// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract NOXStakingV3 is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant YEAR1_EMISSION = 28_000_000 * 1e18;
    uint256 public constant YEAR2_EMISSION = 12_000_000 * 1e18;
    uint256 public constant YEAR_DURATION = 365 days;
    uint256 public constant MAX_POSITIONS = 10;

    uint256 public constant BOOST_0_NFT = 10000;
    uint256 public constant BOOST_1_NFT = 12500;
    uint256 public constant BOOST_2_NFT = 15000;
    uint256 public constant BOOST_3_NFT = 17500;
    uint256 public constant BOOST_4_NFT = 20000;
    uint256 public constant BOOST_5_NFT = 25000;

    uint256 public constant LOCK_30_DAYS = 30 days;
    uint256 public constant LOCK_60_DAYS = 60 days;
    uint256 public constant LOCK_90_DAYS = 90 days;
    uint256 public constant LOCK_180_DAYS = 180 days;
    uint256 public constant LOCK_365_DAYS = 365 days;

    uint256 public constant LOCK_BOOST_NONE = 10000;
    uint256 public constant LOCK_BOOST_30 = 12000;
    uint256 public constant LOCK_BOOST_60 = 14000;
    uint256 public constant LOCK_BOOST_90 = 16000;
    uint256 public constant LOCK_BOOST_180 = 18000;
    uint256 public constant LOCK_BOOST_365 = 25000;

    IERC20 public noxToken;
    IERC721 public zeroStatePass;

    struct UserStakeV2 {
        uint256 amount;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateTime;
    }
    mapping(address => UserStakeV2) internal _v2Stakes;

    uint256 public totalStaked;
    uint256 public totalWeightedStake;
    uint256 public genesisTime;
    uint256 public accRewardPerShare;
    uint256 public lastRewardTime;
    uint256 public totalRewardsDistributed;

    struct UserLockV2 {
        uint256 lockPeriod;
        uint256 lockEndTime;
    }
    mapping(address => UserLockV2) internal _v2Locks;

    uint256 public earlyUnlockPenaltyBps;
    uint256 public totalPenaltiesBurned;

    struct Position {
        uint256 amount;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint256 lockPeriod;
        uint256 lockEndTime;
        uint256 createdAt;
        bool active;
    }

    struct UserInfo {
        uint256 pendingRewards;
        uint256 positionCount;
        bool v2Migrated;
    }

    mapping(address => UserInfo) public userInfo;
    mapping(address => mapping(uint256 => Position)) public positions;

    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event Staked(address indexed user, uint256 amount, uint256 weightedAmount);
    event StakedLocked(address indexed user, uint256 amount, uint256 weightedAmount, uint256 lockPeriod, uint256 lockEndTime);
    event PositionCreated(address indexed user, uint256 indexed positionId, uint256 amount, uint256 lockPeriod);
    event PositionUnstaked(address indexed user, uint256 indexed positionId, uint256 amount);
    event EarlyUnlock(address indexed user, uint256 indexed positionId, uint256 amount, uint256 penaltyAmount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event BoostUpdated(address indexed user, uint256 newWeightedAmount);
    event V2Migrated(address indexed user, uint256 amount, uint256 positionId);
    event PenaltyBpsUpdated(uint256 oldBps, uint256 newBps);
    event GenesisTimeSet(uint256 timestamp);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error InvalidLockPeriod();
    error PositionLocked();
    error PositionNotFound();
    error PositionNotActive();
    error MaxPositionsReached();
    error GenesisAlreadySet();
    error GenesisNotSet();
    error NoRewardsToClaim();
    error TransferFailed();
    error ReentrancyGuard();
    error InsufficientStake();
    error InvalidPenaltyBps();
    error StakeLocked();
    error CannotReduceLock();

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuard();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    modifier whenGenesisSet() {
        if (genesisTime == 0) revert GenesisNotSet();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _noxToken, address _zeroStatePass, address _admin) public initializer {
        if (_noxToken == address(0) || _zeroStatePass == address(0) || _admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        noxToken = IERC20(_noxToken);
        zeroStatePass = IERC721(_zeroStatePass);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        _reentrancyStatus = _NOT_ENTERED;
    }

    function initializeV3(uint256 _penaltyBps) external onlyRole(ADMIN_ROLE) {
        require(_penaltyBps <= 5000, "Max 50% penalty");
        _reentrancyStatus = _NOT_ENTERED;
        earlyUnlockPenaltyBps = _penaltyBps;
    }

    function version() external pure returns (string memory) {
        return "3.0.0";
    }

    function getBoostMultiplier(uint256 nftCount) public pure returns (uint256) {
        if (nftCount == 0) return BOOST_0_NFT;
        if (nftCount == 1) return BOOST_1_NFT;
        if (nftCount == 2) return BOOST_2_NFT;
        if (nftCount == 3) return BOOST_3_NFT;
        if (nftCount == 4) return BOOST_4_NFT;
        return BOOST_5_NFT;
    }

    function getLockBoostMultiplier(uint256 lockPeriod) public pure returns (uint256) {
        if (lockPeriod >= LOCK_365_DAYS) return LOCK_BOOST_365;
        if (lockPeriod >= LOCK_180_DAYS) return LOCK_BOOST_180;
        if (lockPeriod >= LOCK_90_DAYS) return LOCK_BOOST_90;
        if (lockPeriod >= LOCK_60_DAYS) return LOCK_BOOST_60;
        if (lockPeriod >= LOCK_30_DAYS) return LOCK_BOOST_30;
        return LOCK_BOOST_NONE;
    }

    function _isValidLockPeriod(uint256 lockPeriod) internal pure returns (bool) {
        return lockPeriod == 0 ||
               lockPeriod == LOCK_30_DAYS ||
               lockPeriod == LOCK_60_DAYS ||
               lockPeriod == LOCK_90_DAYS ||
               lockPeriod == LOCK_180_DAYS ||
               lockPeriod == LOCK_365_DAYS;
    }

    function calculateWeightedAmount(address user, uint256 amount, uint256 lockPeriod, uint256 lockEndTime) public view returns (uint256) {
        uint256 nftCount = zeroStatePass.balanceOf(user);
        uint256 nftBoost = getBoostMultiplier(nftCount);
        uint256 lockBoost = LOCK_BOOST_NONE;
        if (lockEndTime > block.timestamp && lockPeriod > 0) {
            lockBoost = getLockBoostMultiplier(lockPeriod);
        }
        return (amount * nftBoost * lockBoost) / 100_000_000;
    }

    function getEmissionRate() public view returns (uint256) {
        if (genesisTime == 0) return 0;
        uint256 elapsed = block.timestamp - genesisTime;
        if (elapsed < YEAR_DURATION) {
            return YEAR1_EMISSION / YEAR_DURATION;
        } else if (elapsed < 2 * YEAR_DURATION) {
            return YEAR2_EMISSION / YEAR_DURATION;
        }
        return 0;
    }

    function _getCurrentAccRewardPerShare() internal view returns (uint256) {
        uint256 accReward = accRewardPerShare;
        if (block.timestamp > lastRewardTime && totalWeightedStake > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = timeElapsed * getEmissionRate();
            accReward += (reward * PRECISION) / totalWeightedStake;
        }
        return accReward;
    }

    function _calculateV2PendingRewards(address user) internal view returns (uint256) {
        UserStakeV2 storage v2 = _v2Stakes[user];
        if (v2.weightedAmount == 0) {
            return v2.pendingRewards;
        }
        uint256 accReward = _getCurrentAccRewardPerShare();
        uint256 accumulated = (v2.weightedAmount * accReward) / PRECISION;
        uint256 pending = accumulated - v2.rewardDebt;
        return v2.pendingRewards + pending;
    }

    function pendingRewards(address user) public view returns (uint256) {
        UserInfo storage info = userInfo[user];

        if (!info.v2Migrated) {
            return _calculateV2PendingRewards(user);
        }

        uint256 pending = info.pendingRewards;
        uint256 accReward = _getCurrentAccRewardPerShare();

        for (uint256 i = 0; i < info.positionCount; i++) {
            Position storage pos = positions[user][i];
            if (pos.active && pos.weightedAmount > 0) {
                uint256 accumulated = (pos.weightedAmount * accReward) / PRECISION;
                if (accumulated > pos.rewardDebt) {
                    pending += accumulated - pos.rewardDebt;
                }
            }
        }
        return pending;
    }

    function _getUserTotals(address user) internal view returns (uint256 totalAmount, uint256 totalWeighted) {
        UserInfo storage info = userInfo[user];

        if (!info.v2Migrated) {
            UserStakeV2 storage v2 = _v2Stakes[user];
            return (v2.amount, v2.weightedAmount);
        }

        for (uint256 i = 0; i < info.positionCount; i++) {
            Position storage pos = positions[user][i];
            if (pos.active) {
                totalAmount += pos.amount;
                totalWeighted += pos.weightedAmount;
            }
        }
    }

    function _getEffectiveLock(address user) internal view returns (uint256 lockPeriod, uint256 lockEndTime) {
        UserInfo storage info = userInfo[user];

        if (!info.v2Migrated) {
            UserLockV2 storage v2Lock = _v2Locks[user];
            if (v2Lock.lockEndTime > block.timestamp) {
                return (v2Lock.lockPeriod, v2Lock.lockEndTime);
            }
            return (0, 0);
        }

        for (uint256 i = 0; i < info.positionCount; i++) {
            Position storage pos = positions[user][i];
            if (pos.active && pos.lockEndTime > block.timestamp && pos.lockEndTime > lockEndTime) {
                lockPeriod = pos.lockPeriod;
                lockEndTime = pos.lockEndTime;
            }
        }
    }

    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 weightedAmount,
        uint256 nftCount,
        uint256 pending,
        uint256 boostMultiplier,
        bool migrated
    ) {
        (stakedAmount, weightedAmount) = _getUserTotals(user);
        nftCount = zeroStatePass.balanceOf(user);
        pending = pendingRewards(user);
        migrated = userInfo[user].v2Migrated;

        (uint256 lockPeriod, uint256 lockEndTime) = _getEffectiveLock(user);
        uint256 nftBoost = getBoostMultiplier(nftCount);
        uint256 lockBoost = LOCK_BOOST_NONE;
        if (lockEndTime > block.timestamp) {
            lockBoost = getLockBoostMultiplier(lockPeriod);
        }
        boostMultiplier = (nftBoost * lockBoost) / 10000;
    }

    function getPosition(address user, uint256 positionId) external view returns (
        uint256 amount,
        uint256 weighted,
        uint256 lockPeriod,
        uint256 lockEndTime,
        uint256 createdAt,
        bool active,
        bool unlocked
    ) {
        Position storage pos = positions[user][positionId];
        return (
            pos.amount,
            pos.weightedAmount,
            pos.lockPeriod,
            pos.lockEndTime,
            pos.createdAt,
            pos.active,
            pos.lockEndTime == 0 || pos.lockEndTime <= block.timestamp
        );
    }

    function getUserPositions(address user) external view returns (
        uint256[] memory ids,
        uint256[] memory amounts,
        uint256[] memory lockPeriods,
        uint256[] memory lockEndTimes,
        uint256[] memory positionCount
    ) {
        UserInfo storage info = userInfo[user];
        uint256 count = info.positionCount;

        ids = new uint256[](count);
        amounts = new uint256[](count);
        lockPeriods = new uint256[](count);
        lockEndTimes = new uint256[](count);
        positionCount = new uint256[](1);
        positionCount[0] = count;

        for (uint256 i = 0; i < count; i++) {
            Position storage pos = positions[user][i];
            ids[i] = i;
            amounts[i] = pos.amount;
            lockPeriods[i] = pos.lockPeriod;
            lockEndTimes[i] = pos.lockEndTime;
        }
    }

    function getActivePositionCount(address user) external view returns (uint256 count) {
        UserInfo storage info = userInfo[user];
        for (uint256 i = 0; i < info.positionCount; i++) {
            if (positions[user][i].active) count++;
        }
    }

    function _updateGlobalRewards() internal {
        if (block.timestamp <= lastRewardTime) return;
        if (totalWeightedStake > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = timeElapsed * getEmissionRate();
            accRewardPerShare += (reward * PRECISION) / totalWeightedStake;
        }
        lastRewardTime = block.timestamp;
    }

    function _harvestPositionRewards(address user) internal {
        UserInfo storage info = userInfo[user];

        for (uint256 i = 0; i < info.positionCount; i++) {
            Position storage pos = positions[user][i];
            if (!pos.active || pos.weightedAmount == 0) continue;

            uint256 accumulated = (pos.weightedAmount * accRewardPerShare) / PRECISION;
            if (accumulated > pos.rewardDebt) {
                info.pendingRewards += accumulated - pos.rewardDebt;
            }

            if (pos.lockEndTime > 0 && pos.lockEndTime <= block.timestamp) {
                uint256 newWeighted = calculateWeightedAmount(user, pos.amount, 0, 0);
                if (newWeighted != pos.weightedAmount) {
                    totalWeightedStake = totalWeightedStake - pos.weightedAmount + newWeighted;
                    pos.weightedAmount = newWeighted;
                }
                pos.lockPeriod = 0;
                pos.lockEndTime = 0;
            }

            pos.rewardDebt = (pos.weightedAmount * accRewardPerShare) / PRECISION;
        }
    }

    function _migrateV2(address user) internal {
        UserInfo storage info = userInfo[user];
        if (info.v2Migrated) return;

        UserStakeV2 storage v2 = _v2Stakes[user];
        UserLockV2 storage v2Lock = _v2Locks[user];

        if (v2.amount == 0) {
            info.v2Migrated = true;
            return;
        }

        _updateGlobalRewards();

        uint256 v2Pending = 0;
        if (v2.weightedAmount > 0) {
            uint256 accumulated = (v2.weightedAmount * accRewardPerShare) / PRECISION;
            if (accumulated >= v2.rewardDebt) {
                v2Pending = accumulated - v2.rewardDebt + v2.pendingRewards;
            } else {
                v2Pending = v2.pendingRewards;
            }
        } else {
            v2Pending = v2.pendingRewards;
        }

        uint256 lockPeriod = 0;
        uint256 lockEndTime = 0;
        if (v2Lock.lockEndTime > block.timestamp) {
            lockPeriod = v2Lock.lockPeriod;
            lockEndTime = v2Lock.lockEndTime;
        }

        uint256 newWeighted = calculateWeightedAmount(user, v2.amount, lockPeriod, lockEndTime);

        positions[user][0] = Position({
            amount: v2.amount,
            weightedAmount: newWeighted,
            rewardDebt: (newWeighted * accRewardPerShare) / PRECISION,
            lockPeriod: lockPeriod,
            lockEndTime: lockEndTime,
            createdAt: block.timestamp,
            active: true
        });

        info.pendingRewards = v2Pending;
        info.positionCount = 1;
        info.v2Migrated = true;

        if (newWeighted != v2.weightedAmount) {
            totalWeightedStake = totalWeightedStake - v2.weightedAmount + newWeighted;
        }

        emit V2Migrated(user, v2.amount, 0);
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused whenGenesisSet {
        _migrateV2(msg.sender);
        _createPosition(msg.sender, amount, 0);
    }

    function stakeLocked(uint256 amount, uint256 lockPeriod) external nonReentrant whenNotPaused whenGenesisSet {
        if (!_isValidLockPeriod(lockPeriod) || lockPeriod == 0) revert InvalidLockPeriod();
        _migrateV2(msg.sender);
        _createPosition(msg.sender, amount, lockPeriod);
    }

    function _createPosition(address user, uint256 amount, uint256 lockPeriod) internal {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage info = userInfo[user];

        uint256 activeCount = 0;
        for (uint256 i = 0; i < info.positionCount; i++) {
            if (positions[user][i].active) activeCount++;
        }
        if (activeCount >= MAX_POSITIONS) revert MaxPositionsReached();

        _updateGlobalRewards();
        _harvestPositionRewards(user);

        if (!noxToken.transferFrom(user, address(this), amount)) revert TransferFailed();

        uint256 positionId = info.positionCount;
        uint256 lockEndTime = lockPeriod > 0 ? block.timestamp + lockPeriod : 0;
        uint256 weighted = calculateWeightedAmount(user, amount, lockPeriod, lockEndTime);

        positions[user][positionId] = Position({
            amount: amount,
            weightedAmount: weighted,
            rewardDebt: (weighted * accRewardPerShare) / PRECISION,
            lockPeriod: lockPeriod,
            lockEndTime: lockEndTime,
            createdAt: block.timestamp,
            active: true
        });

        info.positionCount++;
        totalStaked += amount;
        totalWeightedStake += weighted;

        if (lockPeriod > 0) {
            emit StakedLocked(user, amount, weighted, lockPeriod, lockEndTime);
        } else {
            emit Staked(user, amount, weighted);
        }
        emit PositionCreated(user, positionId, amount, lockPeriod);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        if (amount == 0) revert ZeroAmount();

        UserInfo storage info = userInfo[msg.sender];
        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);

        uint256 remaining = amount;
        for (uint256 i = 0; i < info.positionCount && remaining > 0; i++) {
            Position storage pos = positions[msg.sender][i];
            if (!pos.active) continue;
            if (pos.lockEndTime > block.timestamp) continue;

            uint256 unstakeFromThis = pos.amount <= remaining ? pos.amount : remaining;
            remaining -= unstakeFromThis;

            if (unstakeFromThis == pos.amount) {
                totalWeightedStake -= pos.weightedAmount;
                totalStaked -= pos.amount;
                pos.active = false;
                pos.amount = 0;
                pos.weightedAmount = 0;
                pos.rewardDebt = 0;
                emit PositionUnstaked(msg.sender, i, unstakeFromThis);
            } else {
                uint256 ratio = (unstakeFromThis * PRECISION) / pos.amount;
                uint256 weightedReduction = (pos.weightedAmount * ratio) / PRECISION;
                totalWeightedStake -= weightedReduction;
                totalStaked -= unstakeFromThis;
                pos.amount -= unstakeFromThis;
                pos.weightedAmount -= weightedReduction;
                pos.rewardDebt = (pos.weightedAmount * accRewardPerShare) / PRECISION;
                emit PositionUnstaked(msg.sender, i, unstakeFromThis);
            }
        }

        if (remaining > 0) revert InsufficientStake();

        if (!noxToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    function unstakePosition(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);

        UserInfo storage info = userInfo[msg.sender];
        if (positionId >= info.positionCount) revert PositionNotFound();

        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.lockEndTime > block.timestamp) revert PositionLocked();

        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);

        uint256 amount = pos.amount;
        totalWeightedStake -= pos.weightedAmount;
        totalStaked -= amount;

        pos.active = false;
        pos.amount = 0;
        pos.weightedAmount = 0;
        pos.rewardDebt = 0;

        if (!noxToken.transfer(msg.sender, amount)) revert TransferFailed();

        emit PositionUnstaked(msg.sender, positionId, amount);
        emit Unstaked(msg.sender, amount);
    }

    function earlyUnlock(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);

        UserInfo storage info = userInfo[msg.sender];
        if (positionId >= info.positionCount) revert PositionNotFound();

        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.lockEndTime == 0 || pos.lockEndTime <= block.timestamp) revert PositionNotFound();

        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);

        uint256 amount = pos.amount;
        uint256 penaltyAmount = (amount * earlyUnlockPenaltyBps) / 10000;
        uint256 returnAmount = amount - penaltyAmount;

        totalWeightedStake -= pos.weightedAmount;
        totalStaked -= amount;

        pos.active = false;
        pos.amount = 0;
        pos.weightedAmount = 0;
        pos.rewardDebt = 0;
        pos.lockPeriod = 0;
        pos.lockEndTime = 0;

        if (penaltyAmount > 0) {
            if (!noxToken.transfer(address(0xdead), penaltyAmount)) revert TransferFailed();
            totalPenaltiesBurned += penaltyAmount;
        }

        if (!noxToken.transfer(msg.sender, returnAmount)) revert TransferFailed();

        emit EarlyUnlock(msg.sender, positionId, amount, penaltyAmount);
        emit Unstaked(msg.sender, returnAmount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);

        UserInfo storage info = userInfo[msg.sender];
        uint256 rewards = info.pendingRewards;
        if (rewards == 0) revert NoRewardsToClaim();

        info.pendingRewards = 0;
        totalRewardsDistributed += rewards;

        if (!noxToken.transfer(msg.sender, rewards)) revert TransferFailed();

        emit RewardsClaimed(msg.sender, rewards);
    }

    function refreshBoost(address user) external nonReentrant {
        _migrateV2(user);
        _updateGlobalRewards();
        _harvestPositionRewards(user);

        UserInfo storage info = userInfo[user];
        for (uint256 i = 0; i < info.positionCount; i++) {
            Position storage pos = positions[user][i];
            if (!pos.active) continue;

            uint256 newWeighted = calculateWeightedAmount(user, pos.amount, pos.lockPeriod, pos.lockEndTime);
            if (newWeighted != pos.weightedAmount) {
                totalWeightedStake = totalWeightedStake - pos.weightedAmount + newWeighted;
                pos.weightedAmount = newWeighted;
                pos.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;
            }
        }

        emit BoostUpdated(user, totalWeightedStake);
    }

    function extendLock(uint256 positionId, uint256 newLockPeriod) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        if (!_isValidLockPeriod(newLockPeriod) || newLockPeriod == 0) revert InvalidLockPeriod();

        UserInfo storage info = userInfo[msg.sender];
        if (positionId >= info.positionCount) revert PositionNotFound();

        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.amount == 0) revert ZeroAmount();

        if (pos.lockEndTime > block.timestamp) {
            uint256 remainingLock = pos.lockEndTime - block.timestamp;
            if (newLockPeriod <= remainingLock) revert CannotReduceLock();
        }

        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);

        pos.lockPeriod = newLockPeriod;
        pos.lockEndTime = block.timestamp + newLockPeriod;

        uint256 newWeighted = calculateWeightedAmount(msg.sender, pos.amount, pos.lockPeriod, pos.lockEndTime);
        totalWeightedStake = totalWeightedStake - pos.weightedAmount + newWeighted;
        pos.weightedAmount = newWeighted;
        pos.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;

        emit StakedLocked(msg.sender, pos.amount, newWeighted, pos.lockPeriod, pos.lockEndTime);
    }

    function setEarlyUnlockPenalty(uint256 newPenaltyBps) external onlyRole(ADMIN_ROLE) {
        if (newPenaltyBps > 5000) revert InvalidPenaltyBps();
        uint256 oldBps = earlyUnlockPenaltyBps;
        earlyUnlockPenaltyBps = newPenaltyBps;
        emit PenaltyBpsUpdated(oldBps, newPenaltyBps);
    }

    function setGenesisTime(uint256 timestamp) external onlyRole(ADMIN_ROLE) {
        if (genesisTime != 0) revert GenesisAlreadySet();
        if (timestamp < block.timestamp) revert GenesisNotSet();
        genesisTime = timestamp;
        lastRewardTime = timestamp;
        emit GenesisTimeSet(timestamp);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function adminMigrate(address user) external onlyRole(ADMIN_ROLE) {
        _migrateV2(user);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
        emit EmergencyWithdraw(token, msg.sender, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
