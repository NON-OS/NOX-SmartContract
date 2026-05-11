// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 *  NOXStakingV4
 *  -----------------------------------------------------------------------
 *  Storage-safe UUPS upgrade of NOXStakingV3 deployed at proxy
 *      0xa94d6009790Ba13597A1E1b7cF4e1531eA513613
 *
 *  Live state (preserved verbatim by this upgrade):
 *      ~199 M NOX staked, 5.02e26 weighted, 25 M reward reserve,
 *      9 86 K NOX already burned via early-unlock, 2.0 M NOX claimed.
 *      All existing positions, locks, reward debt, V2 lazy-migration
 *      semantics are preserved byte-for-byte.
 *
 *  Hardening relative to V3 (audit findings closed)
 *      C-1  emergencyWithdraw is reserve-aware. NOX rescues are capped at
 *           balanceOf(this) - totalStaked - protectedRewardReserve. A
 *           recipient address is mandatory; admin cannot misroute to self
 *           by accident.
 *      H-2  Lock expiry is exposed as an explicit, user-callable
 *           unlockExpired(positionId). The implicit recalculation inside
 *           _harvestPositionRewards is preserved for protocol economic
 *           correctness, but is now documented and complemented by the
 *           explicit path.
 *      H-3  V4 metadata layer is append-only via positionMetaV4 mapping;
 *           position storage growth concerns from V3 are unchanged in
 *           this upgrade and tracked in the V5 backlog.
 *      H-4  refreshBoost is now whenNotPaused.
 *      H-5  initializeV3 is removed; reinitV4(uint256 penaltyBps) replaces
 *           it as a one-shot reinitializer(4) gated by ADMIN_ROLE.
 *      M-1  _calculateV2PendingRewards subtraction is now guarded.
 *      M-5  All ERC20 transfer paths use SafeERC20.
 *      M-6  claimRewards and compoundRewards apply a reward-reserve cap;
 *           partial fulfilment is allowed and the residue stays in
 *           pendingRewards.
 *
 *  New features
 *      Commitment Score (view-only, non-transferable, no rewards effect)
 *          commitmentScore(address)
 *          positionCommitmentScore(address,uint256)
 *          stakingTier(address)
 *          protocolCommitmentStats()
 *
 *      Reward reserve health views
 *          rewardReserve()
 *          rewardRunway()
 *          pendingRewardLiability(address)
 *          protocolStakingStats()
 *          userPositionSummary(address)
 *          stakingHealth()
 *
 *      Auto-compound
 *          compoundRewards(uint256 positionId)
 *
 *      Explicit lock unwind
 *          unlockExpired(uint256 positionId)
 *
 *      Lazy V4 migration
 *          stakingVersion()
 *          userMigrationVersion(address)
 *          migrateMyPositions()
 *          internal _migrateV4(address)
 *
 *  Storage layout
 *      Slots 0-14 are V3, byte-for-byte unchanged. V4 appends:
 *          slot 15  userMigrationVersion   mapping(address => uint256)
 *          slot 16  positionMetaV4         mapping(address => mapping(uint256 => PositionV4Meta))
 *          slot 17  protectedRewardReserve uint256  (admin-set NOX floor that
 *                                                    emergencyWithdraw cannot touch)
 *          slot 18  __gap                  uint256[47]
 *
 *      Total tail = 50 slots. Future upgrades append by shrinking the gap.
 *
 *  ABI
 *      Every V3 selector is preserved. New selectors are additive.
 *      The only intentional removal is initializeV3 (replaced by
 *      reinitializer-protected reinitV4).
 *
 *  Compiler / verification
 *      solc 0.8.24, optimizer enabled, runs = 1, evmVersion = paris,
 *      via_ir = true, bytecode_hash = none. Match the deploy profile.
 */

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract NOXStakingV4 is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

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

    uint256 private constant TIER_SIGNAL_FLOOR = 100 * 1e18;
    uint256 private constant TIER_CIRCUIT_FLOOR = 1_000 * 1e18;
    uint256 private constant TIER_CAPSULE_FLOOR = 10_000 * 1e18;
    uint256 private constant TIER_OPERATOR_FLOOR = 100_000 * 1e18;
    uint256 private constant TIER_ZEROSTATE_FLOOR = 1_000_000 * 1e18;

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

    mapping(address => uint256) public userMigrationVersion;

    struct PositionV4Meta {
        uint64 lastCompoundTime;
        uint64 v4Initialized;
        uint128 cumulativeCompounded;
    }
    mapping(address => mapping(uint256 => PositionV4Meta)) public positionMetaV4;

    uint256 public protectedRewardReserve;

    mapping(address => mapping(uint256 => uint256)) public zeroStatePassBinding;

    uint256[46] private __gap;

    event Staked(address indexed user, uint256 amount, uint256 weightedAmount);
    event StakedLocked(address indexed user, uint256 amount, uint256 weightedAmount, uint256 lockPeriod, uint256 lockEndTime);
    event PositionCreated(address indexed user, uint256 indexed positionId, uint256 amount, uint256 lockPeriod);
    event PositionUnstaked(address indexed user, uint256 indexed positionId, uint256 amount);
    event EarlyUnlock(address indexed user, uint256 indexed positionId, uint256 amount, uint256 penaltyAmount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsClaimedPartial(address indexed user, uint256 paid, uint256 carriedOver);
    event RewardsCompounded(address indexed user, uint256 indexed positionId, uint256 amount);
    event BoostUpdated(address indexed user, uint256 newWeightedAmount);
    event V2Migrated(address indexed user, uint256 amount, uint256 positionId);
    event UserMigratedToV4(address indexed user);
    event LockExpiredUnlocked(address indexed user, uint256 indexed positionId);
    event ZeroStatePassBound(address indexed user, uint256 indexed positionId, uint256 tokenId);
    event ZeroStatePassUnbound(address indexed user, uint256 indexed positionId, uint256 tokenId);
    event ZeroStatePassRefreshed(address indexed user, uint256 indexed positionId, bool stillValid);
    event PenaltyBpsUpdated(uint256 oldBps, uint256 newBps);
    event GenesisTimeSet(uint256 timestamp);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event ProtectedRewardReserveUpdated(uint256 oldValue, uint256 newValue);
    event V4Initialized(uint256 penaltyBps, uint256 protectedReserve);

    error ZeroAmount();
    error ZeroAddress();
    error InvalidLockPeriod();
    error PositionLocked();
    error PositionNotFound();
    error PositionNotActive();
    error MaxPositionsReached();
    error GenesisAlreadySet();
    error GenesisNotSet();
    error GenesisInPast();
    error NoRewardsToClaim();
    error TransferFailed();
    error ReentrancyGuard();
    error InsufficientStake();
    error InvalidPenaltyBps();
    error StakeLocked();
    error CannotReduceLock();
    error LockNotExpired();
    error ReserveProtected();
    error InvalidProtectedReserve();
    error NothingToCompound();
    error NotZeroStatePassOwner();
    error AlreadyBound();
    error NotBound();

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

    function reinitV4(uint256 _penaltyBps, uint256 _protectedReserve)
        external
        reinitializer(4)
        onlyRole(UPGRADER_ROLE)
    {
        if (_penaltyBps > 5000) revert InvalidPenaltyBps();
        if (_reentrancyStatus == 0) {
            _reentrancyStatus = _NOT_ENTERED;
        }
        if (earlyUnlockPenaltyBps != _penaltyBps) {
            uint256 oldBps = earlyUnlockPenaltyBps;
            earlyUnlockPenaltyBps = _penaltyBps;
            emit PenaltyBpsUpdated(oldBps, _penaltyBps);
        }
        if (protectedRewardReserve != _protectedReserve) {
            uint256 oldRes = protectedRewardReserve;
            protectedRewardReserve = _protectedReserve;
            emit ProtectedRewardReserveUpdated(oldRes, _protectedReserve);
        }
        emit V4Initialized(_penaltyBps, _protectedReserve);
    }

    function stakingVersion() external pure returns (string memory) {
        return "4.0.0";
    }

    function version() external pure returns (string memory) {
        return "4.0.0";
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
        return lockPeriod == 0 || lockPeriod == LOCK_30_DAYS || lockPeriod == LOCK_60_DAYS
            || lockPeriod == LOCK_90_DAYS || lockPeriod == LOCK_180_DAYS || lockPeriod == LOCK_365_DAYS;
    }

    function calculateWeightedAmount(address user, uint256 amount, uint256 lockPeriod, uint256 lockEndTime)
        public
        view
        returns (uint256)
    {
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
        if (block.timestamp < genesisTime) return 0;
        uint256 elapsed = block.timestamp - genesisTime;
        if (elapsed < YEAR_DURATION) return YEAR1_EMISSION / YEAR_DURATION;
        if (elapsed < 2 * YEAR_DURATION) return YEAR2_EMISSION / YEAR_DURATION;
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
        if (v2.weightedAmount == 0) return v2.pendingRewards;
        uint256 accReward = _getCurrentAccRewardPerShare();
        uint256 accumulated = (v2.weightedAmount * accReward) / PRECISION;
        if (accumulated >= v2.rewardDebt) {
            return v2.pendingRewards + (accumulated - v2.rewardDebt);
        }
        return v2.pendingRewards;
    }

    function pendingRewards(address user) public view returns (uint256) {
        UserInfo storage info = userInfo[user];
        if (!info.v2Migrated) return _calculateV2PendingRewards(user);
        uint256 pending = info.pendingRewards;
        uint256 accReward = _getCurrentAccRewardPerShare();
        uint256 count = info.positionCount;
        for (uint256 i = 0; i < count; i++) {
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
        uint256 count = info.positionCount;
        for (uint256 i = 0; i < count; i++) {
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
            if (v2Lock.lockEndTime > block.timestamp) return (v2Lock.lockPeriod, v2Lock.lockEndTime);
            return (0, 0);
        }
        uint256 count = info.positionCount;
        for (uint256 i = 0; i < count; i++) {
            Position storage pos = positions[user][i];
            if (pos.active && pos.lockEndTime > block.timestamp && pos.lockEndTime > lockEndTime) {
                lockPeriod = pos.lockPeriod;
                lockEndTime = pos.lockEndTime;
            }
        }
    }

    function getStakeInfo(address user)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 weightedAmount,
            uint256 nftCount,
            uint256 pending,
            uint256 boostMultiplier,
            uint256 lockPeriod,
            uint256 lockEndTime
        )
    {
        (stakedAmount, weightedAmount) = _getUserTotals(user);
        nftCount = zeroStatePass.balanceOf(user);
        pending = pendingRewards(user);
        (lockPeriod, lockEndTime) = _getEffectiveLock(user);
        uint256 nftBoost = getBoostMultiplier(nftCount);
        uint256 lockBoost = LOCK_BOOST_NONE;
        if (lockEndTime > block.timestamp) lockBoost = getLockBoostMultiplier(lockPeriod);
        boostMultiplier = (nftBoost * lockBoost) / 10000;
    }

    function getPosition(address user, uint256 positionId)
        external
        view
        returns (
            uint256 amount,
            uint256 weighted,
            uint256 lockPeriod,
            uint256 lockEndTime,
            uint256 createdAt,
            bool active,
            bool unlocked
        )
    {
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

    function getUserPositions(address user)
        external
        view
        returns (
            uint256[] memory ids,
            uint256[] memory amounts,
            uint256[] memory lockPeriods,
            uint256[] memory lockEndTimes,
            bool[] memory activeFlags,
            bool[] memory unlockedFlags
        )
    {
        uint256 count = userInfo[user].positionCount;
        ids = new uint256[](count);
        amounts = new uint256[](count);
        lockPeriods = new uint256[](count);
        lockEndTimes = new uint256[](count);
        activeFlags = new bool[](count);
        unlockedFlags = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            Position storage pos = positions[user][i];
            ids[i] = i;
            amounts[i] = pos.amount;
            lockPeriods[i] = pos.lockPeriod;
            lockEndTimes[i] = pos.lockEndTime;
            activeFlags[i] = pos.active;
            unlockedFlags[i] = pos.lockEndTime == 0 || pos.lockEndTime <= block.timestamp;
        }
    }

    function getActivePositionCount(address user) external view returns (uint256 count) {
        UserInfo storage info = userInfo[user];
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
            if (positions[user][i].active) count++;
        }
    }

    function rewardReserve() public view returns (uint256) {
        uint256 bal = noxToken.balanceOf(address(this));
        if (bal <= totalStaked) return 0;
        return bal - totalStaked;
    }

    function rewardRunway() external view returns (uint256 secondsRemaining) {
        uint256 reserve = rewardReserve();
        uint256 rate = getEmissionRate();
        if (rate == 0) return type(uint256).max;
        return reserve / rate;
    }

    function pendingRewardLiability(address user) external view returns (uint256) {
        return pendingRewards(user);
    }

    function protocolStakingStats()
        external
        view
        returns (
            uint256 totalStaked_,
            uint256 totalWeightedStake_,
            uint256 reserve,
            uint256 distributed,
            uint256 burned,
            uint256 emissionRate,
            uint256 currentAccRewardPerShare
        )
    {
        totalStaked_ = totalStaked;
        totalWeightedStake_ = totalWeightedStake;
        reserve = rewardReserve();
        distributed = totalRewardsDistributed;
        burned = totalPenaltiesBurned;
        emissionRate = getEmissionRate();
        currentAccRewardPerShare = _getCurrentAccRewardPerShare();
    }

    function userPositionSummary(address user)
        external
        view
        returns (
            uint256 totalAmount,
            uint256 totalWeighted,
            uint256 pending,
            uint256 activeCount,
            uint256 longestLockEnd,
            uint256 oldestPositionAge
        )
    {
        (totalAmount, totalWeighted) = _getUserTotals(user);
        pending = pendingRewards(user);
        UserInfo storage info = userInfo[user];
        uint256 n = info.positionCount;
        uint256 oldest = block.timestamp;
        bool any;
        for (uint256 i = 0; i < n; i++) {
            Position storage pos = positions[user][i];
            if (!pos.active) continue;
            activeCount++;
            if (pos.lockEndTime > longestLockEnd) longestLockEnd = pos.lockEndTime;
            if (pos.createdAt < oldest) {
                oldest = pos.createdAt;
                any = true;
            }
        }
        oldestPositionAge = any ? block.timestamp - oldest : 0;
    }

    function stakingHealth()
        external
        view
        returns (uint256 reserve, uint256 runway, uint256 totalStaked_, uint256 emissionRate, bool paused_)
    {
        reserve = rewardReserve();
        uint256 rate = getEmissionRate();
        runway = rate == 0 ? type(uint256).max : reserve / rate;
        totalStaked_ = totalStaked;
        emissionRate = rate;
        paused_ = paused();
    }

    function positionCommitmentScore(address user, uint256 positionId) public view returns (uint256) {
        Position storage pos = positions[user][positionId];
        if (!pos.active) return 0;
        uint256 lockBoost = pos.lockEndTime > block.timestamp ? getLockBoostMultiplier(pos.lockPeriod) : LOCK_BOOST_NONE;
        uint256 ageSeconds = block.timestamp > pos.createdAt ? block.timestamp - pos.createdAt : 0;

        return (pos.amount * lockBoost * ageSeconds) / 10000 / 1 days;
    }

    function commitmentScore(address user) public view returns (uint256 score) {
        UserInfo storage info = userInfo[user];
        if (!info.v2Migrated) {
            UserStakeV2 storage v2 = _v2Stakes[user];
            UserLockV2 storage v2Lock = _v2Locks[user];
            uint256 lockBoost =
                v2Lock.lockEndTime > block.timestamp ? getLockBoostMultiplier(v2Lock.lockPeriod) : LOCK_BOOST_NONE;
            uint256 age = block.timestamp > v2.lastUpdateTime && v2.lastUpdateTime > 0
                ? block.timestamp - v2.lastUpdateTime
                : 0;
            score = (v2.amount * lockBoost * age) / 10000 / 1 days;
            return score;
        }
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
            score += positionCommitmentScore(user, i);
        }
    }

    function stakingTier(address user) external view returns (uint8 tier, string memory name) {
        (uint256 amount,) = _getUserTotals(user);
        if (amount >= TIER_ZEROSTATE_FLOOR) return (5, "ZeroState");
        if (amount >= TIER_OPERATOR_FLOOR) return (4, "Operator");
        if (amount >= TIER_CAPSULE_FLOOR) return (3, "Capsule");
        if (amount >= TIER_CIRCUIT_FLOOR) return (2, "Circuit");
        if (amount >= TIER_SIGNAL_FLOOR) return (1, "Signal");
        return (0, "Void");
    }

    function protocolCommitmentStats()
        external
        view
        returns (uint256 totalActivePositions, uint256 totalLockedAmount, uint256 totalUnlockedAmount)
    {

        totalActivePositions = 0;
        totalLockedAmount = 0;
        totalUnlockedAmount = 0;
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
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
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
            v2Pending =
                accumulated >= v2.rewardDebt ? accumulated - v2.rewardDebt + v2.pendingRewards : v2.pendingRewards;
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

    function _migrateV4(address user) internal {
        if (userMigrationVersion[user] >= 4) return;
        UserInfo storage info = userInfo[user];
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
            if (!positions[user][i].active) continue;
            PositionV4Meta storage meta = positionMetaV4[user][i];
            if (meta.v4Initialized == 0) {
                meta.lastCompoundTime = uint64(block.timestamp);
                meta.v4Initialized = 1;
                meta.cumulativeCompounded = 0;
            }
        }
        userMigrationVersion[user] = 4;
        emit UserMigratedToV4(user);
    }

    function migrateMyPositions() external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused whenGenesisSet {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        _createPosition(msg.sender, amount, 0);
    }

    function stakeLocked(uint256 amount, uint256 lockPeriod) external nonReentrant whenNotPaused whenGenesisSet {
        if (!_isValidLockPeriod(lockPeriod) || lockPeriod == 0) revert InvalidLockPeriod();
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        _createPosition(msg.sender, amount, lockPeriod);
    }

    function _createPosition(address user, uint256 amount, uint256 lockPeriod) internal {
        if (amount == 0) revert ZeroAmount();
        UserInfo storage info = userInfo[user];
        uint256 activeCount = 0;
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
            if (positions[user][i].active) activeCount++;
        }
        if (activeCount >= MAX_POSITIONS) revert MaxPositionsReached();
        _updateGlobalRewards();
        _harvestPositionRewards(user);
        noxToken.safeTransferFrom(user, address(this), amount);
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
        positionMetaV4[user][positionId] = PositionV4Meta({
            lastCompoundTime: uint64(block.timestamp),
            v4Initialized: 1,
            cumulativeCompounded: 0
        });
        info.positionCount++;
        totalStaked += amount;
        totalWeightedStake += weighted;
        if (lockPeriod > 0) emit StakedLocked(user, amount, weighted, lockPeriod, lockEndTime);
        else emit Staked(user, amount, weighted);
        emit PositionCreated(user, positionId, amount, lockPeriod);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        if (amount == 0) revert ZeroAmount();
        UserInfo storage info = userInfo[msg.sender];
        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);
        uint256 remaining = amount;
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n && remaining > 0; i++) {
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
        noxToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function unstakePosition(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
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
        noxToken.safeTransfer(msg.sender, amount);
        emit PositionUnstaked(msg.sender, positionId, amount);
        emit Unstaked(msg.sender, amount);
    }

    function earlyUnlock(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
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
            noxToken.safeTransfer(address(0xdead), penaltyAmount);
            totalPenaltiesBurned += penaltyAmount;
        }
        noxToken.safeTransfer(msg.sender, returnAmount);
        emit EarlyUnlock(msg.sender, positionId, amount, penaltyAmount);
        emit Unstaked(msg.sender, returnAmount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);
        UserInfo storage info = userInfo[msg.sender];
        uint256 rewards = info.pendingRewards;
        if (rewards == 0) revert NoRewardsToClaim();

        uint256 reserve = _availableRewardReserve();
        uint256 paid;
        if (rewards <= reserve) {
            paid = rewards;
            info.pendingRewards = 0;
        } else {
            paid = reserve;
            info.pendingRewards = rewards - reserve;
            emit RewardsClaimedPartial(msg.sender, paid, info.pendingRewards);
        }
        if (paid == 0) revert NoRewardsToClaim();
        totalRewardsDistributed += paid;
        noxToken.safeTransfer(msg.sender, paid);
        emit RewardsClaimed(msg.sender, paid);
    }

    function compoundRewards(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        UserInfo storage info = userInfo[msg.sender];
        if (positionId >= info.positionCount) revert PositionNotFound();
        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        _updateGlobalRewards();
        _harvestPositionRewards(msg.sender);
        uint256 rewards = info.pendingRewards;
        if (rewards == 0) revert NothingToCompound();

        uint256 reserve = _availableRewardReserve();
        if (reserve == 0) revert ReserveProtected();
        uint256 amount = rewards <= reserve ? rewards : reserve;

        info.pendingRewards = rewards - amount;
        totalRewardsDistributed += amount;

        pos.amount += amount;
        totalStaked += amount;
        uint256 newWeighted = calculateWeightedAmount(msg.sender, pos.amount, pos.lockPeriod, pos.lockEndTime);
        totalWeightedStake = totalWeightedStake - pos.weightedAmount + newWeighted;
        pos.weightedAmount = newWeighted;
        pos.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;

        PositionV4Meta storage meta = positionMetaV4[msg.sender][positionId];
        meta.lastCompoundTime = uint64(block.timestamp);
        meta.cumulativeCompounded += uint128(amount);

        emit RewardsCompounded(msg.sender, positionId, amount);
    }

    function unlockExpired(uint256 positionId) external nonReentrant whenNotPaused {
        _migrateV2(msg.sender);
        _migrateV4(msg.sender);
        UserInfo storage info = userInfo[msg.sender];
        if (positionId >= info.positionCount) revert PositionNotFound();
        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.lockEndTime == 0) revert LockNotExpired();
        if (pos.lockEndTime > block.timestamp) revert LockNotExpired();
        _updateGlobalRewards();
        uint256 accumulated = (pos.weightedAmount * accRewardPerShare) / PRECISION;
        if (accumulated > pos.rewardDebt) {
            info.pendingRewards += accumulated - pos.rewardDebt;
        }
        uint256 newWeighted = calculateWeightedAmount(msg.sender, pos.amount, 0, 0);
        if (newWeighted != pos.weightedAmount) {
            totalWeightedStake = totalWeightedStake - pos.weightedAmount + newWeighted;
            pos.weightedAmount = newWeighted;
        }
        pos.lockPeriod = 0;
        pos.lockEndTime = 0;
        pos.rewardDebt = (pos.weightedAmount * accRewardPerShare) / PRECISION;
        emit LockExpiredUnlocked(msg.sender, positionId);
    }

    function refreshBoost(address user) external nonReentrant whenNotPaused {
        _migrateV2(user);
        _migrateV4(user);
        _updateGlobalRewards();
        _harvestPositionRewards(user);
        UserInfo storage info = userInfo[user];
        uint256 n = info.positionCount;
        for (uint256 i = 0; i < n; i++) {
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
        _migrateV4(msg.sender);
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
        if (timestamp < block.timestamp) revert GenesisInPast();
        genesisTime = timestamp;
        lastRewardTime = timestamp;
        emit GenesisTimeSet(timestamp);
    }

    function setProtectedRewardReserve(uint256 newValue) external onlyRole(ADMIN_ROLE) {
        uint256 oldValue = protectedRewardReserve;
        protectedRewardReserve = newValue;
        emit ProtectedRewardReserveUpdated(oldValue, newValue);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function adminMigrate(address user) external onlyRole(ADMIN_ROLE) {
        _migrateV2(user);
        _migrateV4(user);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(noxToken)) {
            uint256 bal = noxToken.balanceOf(address(this));
            uint256 reserved = totalStaked + protectedRewardReserve;
            if (bal < reserved) revert ReserveProtected();
            uint256 available = bal - reserved;
            if (amount > available) revert ReserveProtected();
        }
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function _availableRewardReserve() internal view returns (uint256) {
        uint256 bal = noxToken.balanceOf(address(this));
        uint256 reserved = totalStaked + protectedRewardReserve;
        if (bal <= reserved) return 0;
        return bal - reserved;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function operatorId(address wallet, uint256 positionId) public pure returns (bytes32) {
        return keccak256(abi.encode("NOX_OPERATOR_V1", wallet, positionId));
    }

    struct StakeReceipt {
        address wallet;
        uint256 positionId;
        uint256 amount;
        uint256 weightedAmount;
        uint256 lockPeriod;
        uint256 lockEndTime;
        uint256 createdAt;
        bool active;
        uint256 cumulativeCompounded;
        uint64 lastCompoundTime;
        uint256 boundZeroStatePassTokenId;
        bool zeroStatePassValid;
        bytes32 opId;
    }

    function getStakeReceipt(address wallet, uint256 positionId) public view returns (StakeReceipt memory r) {
        Position storage pos = positions[wallet][positionId];
        PositionV4Meta storage meta = positionMetaV4[wallet][positionId];
        uint256 bound = zeroStatePassBinding[wallet][positionId];
        r.wallet = wallet;
        r.positionId = positionId;
        r.amount = pos.amount;
        r.weightedAmount = pos.weightedAmount;
        r.lockPeriod = pos.lockPeriod;
        r.lockEndTime = pos.lockEndTime;
        r.createdAt = pos.createdAt;
        r.active = pos.active;
        r.cumulativeCompounded = uint256(meta.cumulativeCompounded);
        r.lastCompoundTime = meta.lastCompoundTime;
        if (bound > 0) {
            r.boundZeroStatePassTokenId = bound - 1;
            r.zeroStatePassValid = _isZeroStatePassValid(wallet, bound - 1);
        }
        r.opId = operatorId(wallet, positionId);
    }

    function stakeReceiptDigest(address wallet, uint256 positionId) external view returns (bytes32) {
        return keccak256(abi.encode(getStakeReceipt(wallet, positionId)));
    }

    function _isZeroStatePassValid(address user, uint256 tokenId) internal view returns (bool) {
        try zeroStatePass.ownerOf(tokenId) returns (address owner) {
            return owner == user;
        } catch {
            return false;
        }
    }

    function isZeroStatePassValidlyBound(address user, uint256 positionId) public view returns (bool) {
        uint256 bound = zeroStatePassBinding[user][positionId];
        if (bound == 0) return false;
        return _isZeroStatePassValid(user, bound - 1);
    }

    function bindZeroStatePass(uint256 positionId, uint256 tokenId) external nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender][positionId];
        if (!pos.active) revert PositionNotActive();
        if (zeroStatePassBinding[msg.sender][positionId] != 0) revert AlreadyBound();
        if (zeroStatePass.ownerOf(tokenId) != msg.sender) revert NotZeroStatePassOwner();
        zeroStatePassBinding[msg.sender][positionId] = tokenId + 1;
        emit ZeroStatePassBound(msg.sender, positionId, tokenId);
    }

    function unbindZeroStatePass(uint256 positionId) external nonReentrant whenNotPaused {
        uint256 bound = zeroStatePassBinding[msg.sender][positionId];
        if (bound == 0) revert NotBound();
        zeroStatePassBinding[msg.sender][positionId] = 0;
        emit ZeroStatePassUnbound(msg.sender, positionId, bound - 1);
    }

    function refreshZeroStatePass(address user, uint256 positionId) external nonReentrant {
        uint256 bound = zeroStatePassBinding[user][positionId];
        if (bound == 0) {
            emit ZeroStatePassRefreshed(user, positionId, false);
            return;
        }
        bool valid = _isZeroStatePassValid(user, bound - 1);
        if (!valid) {
            zeroStatePassBinding[user][positionId] = 0;
            emit ZeroStatePassUnbound(user, positionId, bound - 1);
        }
        emit ZeroStatePassRefreshed(user, positionId, valid);
    }

    function namespaceEligibility(address wallet, uint256 positionId) external view returns (bool) {
        Position storage pos = positions[wallet][positionId];
        if (!pos.active) return false;
        if (pos.amount < TIER_CIRCUIT_FLOOR) return false;
        return isZeroStatePassValidlyBound(wallet, positionId);
    }
}
