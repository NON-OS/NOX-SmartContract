// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

abstract contract ReentrancyGuardUpgradeable is Initializable {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    struct ReentrancyStorage {
        uint256 status;
    }

    bytes32 private constant REENTRANCY_STORAGE = keccak256("nox.storage.ReentrancyGuard");

    function _getReentrancyStorage() private pure returns (ReentrancyStorage storage $) {
        bytes32 slot = REENTRANCY_STORAGE;
        assembly { $.slot := slot }
    }

    error ReentrancyGuardReentrantCall();

    function __ReentrancyGuard_init() internal onlyInitializing {
        _getReentrancyStorage().status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        ReentrancyStorage storage $ = _getReentrancyStorage();
        if ($.status == ENTERED) revert ReentrancyGuardReentrantCall();
        $.status = ENTERED;
        _;
        $.status = NOT_ENTERED;
    }
}

contract NOXStaking is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IERC20 public noxToken;
    IERC721 public zeroStatePass;

    struct UserStake {
        uint256 amount;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateTime;
    }

    mapping(address => UserStake) public stakes;

    uint256 public totalStaked;
    uint256 public totalWeightedStake;
    uint256 public genesisTime;
    uint256 public accRewardPerShare;
    uint256 public lastRewardTime;
    uint256 public totalRewardsDistributed;

    uint256 public constant YEAR1_EMISSION = 28_000_000 * 1e18;
    uint256 public constant YEAR2_EMISSION = 12_000_000 * 1e18;
    uint256 public constant YEAR_DURATION = 365 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public constant BOOST_0_NFT = 10000;
    uint256 public constant BOOST_1_NFT = 12500;
    uint256 public constant BOOST_2_NFT = 15000;
    uint256 public constant BOOST_3_NFT = 17500;
    uint256 public constant BOOST_4_NFT = 20000;
    uint256 public constant BOOST_5_NFT = 25000;

    event Staked(address indexed user, uint256 amount, uint256 weightedAmount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event BoostUpdated(address indexed user, uint256 newWeightedAmount);
    event GenesisTimeSet(uint256 timestamp);

    error ZeroAmount();
    error InsufficientStake();
    error GenesisAlreadySet();
    error GenesisNotSet();
    error NoRewardsToClaim();
    error TransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _noxToken,
        address _zeroStatePass,
        address _admin
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        noxToken = IERC20(_noxToken);
        zeroStatePass = IERC721(_zeroStatePass);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    function getBoostMultiplier(uint256 nftCount) public pure returns (uint256) {
        if (nftCount == 0) return BOOST_0_NFT;
        if (nftCount == 1) return BOOST_1_NFT;
        if (nftCount == 2) return BOOST_2_NFT;
        if (nftCount == 3) return BOOST_3_NFT;
        if (nftCount == 4) return BOOST_4_NFT;
        return BOOST_5_NFT;
    }

    function calculateWeightedAmount(address user, uint256 amount) public view returns (uint256) {
        uint256 nftCount = zeroStatePass.balanceOf(user);
        uint256 boost = getBoostMultiplier(nftCount);
        return (amount * boost) / 10000;
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

    function pendingRewards(address user) public view returns (uint256) {
        UserStake storage userStake = stakes[user];
        if (userStake.weightedAmount == 0) {
            return userStake.pendingRewards;
        }
        uint256 accReward = accRewardPerShare;
        if (block.timestamp > lastRewardTime && totalWeightedStake > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = timeElapsed * getEmissionRate();
            accReward += (reward * PRECISION) / totalWeightedStake;
        }
        uint256 pending = (userStake.weightedAmount * accReward) / PRECISION - userStake.rewardDebt;
        return userStake.pendingRewards + pending;
    }

    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 weightedAmount,
        uint256 nftCount,
        uint256 pending,
        uint256 boostMultiplier
    ) {
        UserStake storage userStake = stakes[user];
        nftCount = zeroStatePass.balanceOf(user);
        return (
            userStake.amount,
            userStake.weightedAmount,
            nftCount,
            pendingRewards(user),
            getBoostMultiplier(nftCount)
        );
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (genesisTime == 0) revert GenesisNotSet();
        _updateRewards(msg.sender);
        if (!noxToken.transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        UserStake storage userStake = stakes[msg.sender];
        userStake.amount += amount;
        uint256 newWeighted = calculateWeightedAmount(msg.sender, userStake.amount);
        totalStaked += amount;
        totalWeightedStake = totalWeightedStake - userStake.weightedAmount + newWeighted;
        userStake.weightedAmount = newWeighted;
        userStake.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;
        emit Staked(msg.sender, amount, newWeighted);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        UserStake storage userStake = stakes[msg.sender];
        if (userStake.amount < amount) revert InsufficientStake();
        _updateRewards(msg.sender);
        userStake.amount -= amount;
        uint256 newWeighted = calculateWeightedAmount(msg.sender, userStake.amount);
        totalStaked -= amount;
        totalWeightedStake = totalWeightedStake - userStake.weightedAmount + newWeighted;
        userStake.weightedAmount = newWeighted;
        userStake.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;
        if (!noxToken.transfer(msg.sender, amount)) {
            revert TransferFailed();
        }
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);
        UserStake storage userStake = stakes[msg.sender];
        uint256 rewards = userStake.pendingRewards;
        if (rewards == 0) revert NoRewardsToClaim();
        userStake.pendingRewards = 0;
        totalRewardsDistributed += rewards;
        if (!noxToken.transfer(msg.sender, rewards)) {
            revert TransferFailed();
        }
        emit RewardsClaimed(msg.sender, rewards);
    }

    function refreshBoost(address user) external {
        _updateRewards(user);
        UserStake storage userStake = stakes[user];
        if (userStake.amount == 0) return;
        uint256 newWeighted = calculateWeightedAmount(user, userStake.amount);
        if (newWeighted != userStake.weightedAmount) {
            totalWeightedStake = totalWeightedStake - userStake.weightedAmount + newWeighted;
            userStake.weightedAmount = newWeighted;
            userStake.rewardDebt = (newWeighted * accRewardPerShare) / PRECISION;
            emit BoostUpdated(user, newWeighted);
        }
    }

    function _updateRewards(address user) internal {
        if (block.timestamp > lastRewardTime && totalWeightedStake > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = timeElapsed * getEmissionRate();
            accRewardPerShare += (reward * PRECISION) / totalWeightedStake;
        }
        lastRewardTime = block.timestamp;
        UserStake storage userStake = stakes[user];
        if (userStake.weightedAmount > 0) {
            uint256 pending = (userStake.weightedAmount * accRewardPerShare) / PRECISION - userStake.rewardDebt;
            userStake.pendingRewards += pending;
        }
        userStake.rewardDebt = (userStake.weightedAmount * accRewardPerShare) / PRECISION;
        userStake.lastUpdateTime = block.timestamp;
    }

    function setGenesisTime(uint256 timestamp) external onlyRole(ADMIN_ROLE) {
        if (genesisTime != 0) revert GenesisAlreadySet();
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

    function emergencyWithdraw(address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        IERC20(token).transfer(msg.sender, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
