// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract NOXRewardsV2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardTransient {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    IERC20 public noxToken;
    address public signer;
    uint96 public starReward;
    uint96 public issueReward;
    uint96 public defaultPRReward;
    uint256 public totalDistributed;
    uint128 public totalStarClaims;
    uint64 public totalIssueClaims;
    uint64 public totalPRClaims;

    mapping(bytes32 => bool) public starClaimed;
    mapping(bytes32 => mapping(uint256 => bool)) public issueClaimed;
    mapping(bytes32 => mapping(uint256 => bool)) public prClaimed;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    bytes32 private constant SIG_STAR = keccak256("STAR_CLAIM_V2");
    bytes32 private constant SIG_ISSUE = keccak256("ISSUE_CLAIM_V2");
    bytes32 private constant SIG_PR = keccak256("PR_CLAIM_V2");

    event StarClaimed(address indexed wallet, bytes32 indexed githubHash, uint256 amount);
    event IssueClaimed(address indexed wallet, bytes32 indexed githubHash, uint256 indexed issueId, uint256 amount);
    event PRClaimed(address indexed wallet, bytes32 indexed githubHash, uint256 indexed prId, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event RewardsUpdated(uint96 star, uint96 issue, uint96 pr);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    error InvalidSignature();
    error NonceAlreadyUsed();
    error StarAlreadyClaimed();
    error IssueAlreadyClaimed();
    error PRAlreadyClaimed();
    error InsufficientPoolBalance();
    error ZeroAddress();
    error InvalidAmount();

    constructor() { _disableInitializers(); }

    function initialize(address _noxToken, address _signer, address _owner) public initializer {
        if (_noxToken == address(0) || _signer == address(0) || _owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Pausable_init();
        noxToken = IERC20(_noxToken);
        signer = _signer;
        starReward = 5_000 * 1e18;
        issueReward = 10_000 * 1e18;
        defaultPRReward = 25_000 * 1e18;
    }

    function claimStar(uint256 nonce, bytes32 githubHash, bytes calldata signature) external nonReentrant whenNotPaused {
        if (starClaimed[githubHash]) revert StarAlreadyClaimed();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();
        uint256 reward = starReward;
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, reward, nonce, githubHash, SIG_STAR, block.chainid, address(this)));
        if (messageHash.toEthSignedMessageHash().recover(signature) != signer) revert InvalidSignature();
        if (noxToken.balanceOf(address(this)) < reward) revert InsufficientPoolBalance();
        usedNonces[msg.sender][nonce] = true;
        starClaimed[githubHash] = true;
        unchecked { totalDistributed += reward; totalStarClaims++; }
        noxToken.safeTransfer(msg.sender, reward);
        emit StarClaimed(msg.sender, githubHash, reward);
    }

    function claimIssue(uint256 issueId, uint256 nonce, bytes32 githubHash, bytes calldata signature) external nonReentrant whenNotPaused {
        if (issueClaimed[githubHash][issueId]) revert IssueAlreadyClaimed();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();
        uint256 reward = issueReward;
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, reward, nonce, githubHash, issueId, SIG_ISSUE, block.chainid, address(this)));
        if (messageHash.toEthSignedMessageHash().recover(signature) != signer) revert InvalidSignature();
        if (noxToken.balanceOf(address(this)) < reward) revert InsufficientPoolBalance();
        usedNonces[msg.sender][nonce] = true;
        issueClaimed[githubHash][issueId] = true;
        unchecked { totalDistributed += reward; totalIssueClaims++; }
        noxToken.safeTransfer(msg.sender, reward);
        emit IssueClaimed(msg.sender, githubHash, issueId, reward);
    }

    function claimPR(uint256 prId, uint256 amount, uint256 nonce, bytes32 githubHash, bytes calldata signature) external nonReentrant whenNotPaused {
        if (prClaimed[githubHash][prId]) revert PRAlreadyClaimed();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();
        if (amount == 0) revert InvalidAmount();
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, amount, nonce, githubHash, prId, SIG_PR, block.chainid, address(this)));
        if (messageHash.toEthSignedMessageHash().recover(signature) != signer) revert InvalidSignature();
        if (noxToken.balanceOf(address(this)) < amount) revert InsufficientPoolBalance();
        usedNonces[msg.sender][nonce] = true;
        prClaimed[githubHash][prId] = true;
        unchecked { totalDistributed += amount; totalPRClaims++; }
        noxToken.safeTransfer(msg.sender, amount);
        emit PRClaimed(msg.sender, githubHash, prId, amount);
    }

    function hasClaimedStar(bytes32 githubHash) external view returns (bool) { return starClaimed[githubHash]; }
    function hasClaimedIssue(bytes32 githubHash, uint256 issueId) external view returns (bool) { return issueClaimed[githubHash][issueId]; }
    function hasClaimedPR(bytes32 githubHash, uint256 prId) external view returns (bool) { return prClaimed[githubHash][prId]; }

    function getStats() external view returns (uint256 poolBalance, uint256 distributed, uint256 stars, uint256 issues, uint256 prs) {
        return (noxToken.balanceOf(address(this)), totalDistributed, totalStarClaims, totalIssueClaims, totalPRClaims);
    }

    function getRewards() external view returns (uint256 star, uint256 issue, uint256 pr) {
        return (starReward, issueReward, defaultPRReward);
    }

    function setSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, _signer);
        signer = _signer;
    }

    function setRewards(uint96 _star, uint96 _issue, uint96 _pr) external onlyOwner {
        if (_star == 0 || _issue == 0 || _pr == 0) revert InvalidAmount();
        starReward = _star;
        issueReward = _issue;
        defaultPRReward = _pr;
        emit RewardsUpdated(_star, _issue, _pr);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function emergencyWithdraw(uint256 amount) external onlyOwner {
        if (amount > noxToken.balanceOf(address(this))) revert InsufficientPoolBalance();
        noxToken.safeTransfer(owner(), amount);
        emit EmergencyWithdraw(owner(), amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
    function version() external pure returns (string memory) { return "2.0.0"; }
}
