// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IERC20.sol";

contract NOXBridge is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    address public constant NOX_TOKEN = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    bytes32 public constant CF20_NOX = keccak256("CF20_NOX_CELLFRAME");

    uint256 public constant MIN_BRIDGE_AMOUNT = 100 * 1e18;
    uint256 public constant MAX_BRIDGE_AMOUNT = 10_000_000 * 1e18;
    uint256 public constant BRIDGE_FEE_BPS = 25;
    uint256 public constant MIN_CONFIRMATIONS = 3;
    uint256 private constant BPS_DENOMINATOR = 10000;

    enum BridgeDirection {
        ETH_TO_CF,
        CF_TO_ETH
    }

    enum BridgeStatus {
        PENDING,
        CONFIRMING,
        COMPLETED,
        FAILED,
        REFUNDED
    }

    struct BridgeTransaction {
        bytes32 txId;
        address ethAddress;
        bytes32 cfAddress;
        uint256 amount;
        uint256 fee;
        uint256 netAmount;
        uint256 timestamp;
        uint256 confirmations;
        BridgeDirection direction;
        BridgeStatus status;
        bytes32 cfTxHash;
    }

    struct DailyLimit {
        uint256 date;
        uint256 totalBridged;
    }

    address public feeCollector;
    address public liquidityPool;

    uint256 public totalBridgedToCell;
    uint256 public totalBridgedToEth;
    uint256 public totalFeesCollected;
    uint256 public dailyLimit;
    uint256 private _txCount;

    mapping(bytes32 => BridgeTransaction) public transactions;
    mapping(address => bytes32[]) public userTransactions;
    mapping(bytes32 => mapping(address => bool)) public validatorConfirmations;
    mapping(uint256 => DailyLimit) public dailyLimits;

    bytes32[] public pendingTransactions;
    mapping(bytes32 => uint256) private _pendingIndex;

    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event BridgeToCell(
        bytes32 indexed txId,
        address indexed sender,
        bytes32 cfRecipient,
        uint256 amount,
        uint256 fee
    );
    event BridgeToEth(
        bytes32 indexed txId,
        bytes32 cfSender,
        address indexed recipient,
        uint256 amount
    );
    event BridgeConfirmed(bytes32 indexed txId, address indexed validator, uint256 confirmations);
    event BridgeCompleted(bytes32 indexed txId, bytes32 cfTxHash);
    event BridgeFailed(bytes32 indexed txId, string reason);
    event BridgeRefunded(bytes32 indexed txId, address indexed recipient, uint256 amount);
    event LiquidityAdded(address indexed provider, uint256 amount);
    event LiquidityRemoved(address indexed provider, uint256 amount);
    event DailyLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);

    error ZeroAddress();
    error ZeroAmount();
    error BelowMinimum();
    error AboveMaximum();
    error DailyLimitExceeded();
    error TransactionNotFound();
    error AlreadyConfirmed();
    error AlreadyCompleted();
    error InsufficientConfirmations();
    error InsufficientLiquidity();
    error TransferFailed();
    error InvalidStatus();
    error ReentrancyGuard();

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuard();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _feeCollector,
        address _liquidityPool,
        uint256 _dailyLimit,
        address _admin
    ) public initializer {
        if (_feeCollector == address(0) || _admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        feeCollector = _feeCollector;
        liquidityPool = _liquidityPool != address(0) ? _liquidityPool : address(this);
        dailyLimit = _dailyLimit > 0 ? _dailyLimit : 1_000_000 * 1e18;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(VALIDATOR_ROLE, _admin);

        _reentrancyStatus = _NOT_ENTERED;
    }

    function bridgeToCell(
        uint256 amount,
        bytes32 cfRecipient
    ) external nonReentrant whenNotPaused returns (bytes32 txId) {
        if (amount < MIN_BRIDGE_AMOUNT) revert BelowMinimum();
        if (amount > MAX_BRIDGE_AMOUNT) revert AboveMaximum();
        _checkDailyLimit(amount);

        uint256 fee = (amount * BRIDGE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - fee;

        IERC20 nox = IERC20(NOX_TOKEN);
        if (!nox.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        if (fee > 0) {
            if (!nox.transfer(feeCollector, fee)) revert TransferFailed();
            totalFeesCollected += fee;
        }

        txId = keccak256(abi.encodePacked(
            msg.sender,
            cfRecipient,
            amount,
            block.timestamp,
            _txCount++
        ));

        transactions[txId] = BridgeTransaction({
            txId: txId,
            ethAddress: msg.sender,
            cfAddress: cfRecipient,
            amount: amount,
            fee: fee,
            netAmount: netAmount,
            timestamp: block.timestamp,
            confirmations: 0,
            direction: BridgeDirection.ETH_TO_CF,
            status: BridgeStatus.PENDING,
            cfTxHash: bytes32(0)
        });

        userTransactions[msg.sender].push(txId);
        pendingTransactions.push(txId);
        _pendingIndex[txId] = pendingTransactions.length - 1;

        totalBridgedToCell += netAmount;
        _updateDailyLimit(amount);

        emit BridgeToCell(txId, msg.sender, cfRecipient, amount, fee);
    }

    function confirmBridgeToCell(bytes32 txId, bytes32 cfTxHash) external onlyRole(VALIDATOR_ROLE) {
        BridgeTransaction storage tx_ = transactions[txId];
        if (tx_.txId == bytes32(0)) revert TransactionNotFound();
        if (tx_.status != BridgeStatus.PENDING && tx_.status != BridgeStatus.CONFIRMING) revert InvalidStatus();
        if (validatorConfirmations[txId][msg.sender]) revert AlreadyConfirmed();

        validatorConfirmations[txId][msg.sender] = true;
        tx_.confirmations++;
        tx_.status = BridgeStatus.CONFIRMING;

        emit BridgeConfirmed(txId, msg.sender, tx_.confirmations);

        if (tx_.confirmations >= MIN_CONFIRMATIONS) {
            tx_.status = BridgeStatus.COMPLETED;
            tx_.cfTxHash = cfTxHash;
            _removePending(txId);
            emit BridgeCompleted(txId, cfTxHash);
        }
    }

    function bridgeFromCell(
        bytes32 cfTxHash,
        bytes32 cfSender,
        address ethRecipient,
        uint256 amount,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        if (ethRecipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bytes32 txId = keccak256(abi.encodePacked(cfTxHash, cfSender, ethRecipient, amount));

        BridgeTransaction storage tx_ = transactions[txId];
        if (tx_.status == BridgeStatus.COMPLETED) revert AlreadyCompleted();

        if (tx_.txId == bytes32(0)) {
            tx_.txId = txId;
            tx_.ethAddress = ethRecipient;
            tx_.cfAddress = cfSender;
            tx_.amount = amount;
            tx_.netAmount = amount;
            tx_.timestamp = block.timestamp;
            tx_.direction = BridgeDirection.CF_TO_ETH;
            tx_.status = BridgeStatus.CONFIRMING;
            tx_.cfTxHash = cfTxHash;

            userTransactions[ethRecipient].push(txId);
            pendingTransactions.push(txId);
            _pendingIndex[txId] = pendingTransactions.length - 1;
        }

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(txId, cfTxHash, ethRecipient, amount, signatures[i]);
            if (!hasRole(VALIDATOR_ROLE, signer)) continue;
            if (validatorConfirmations[txId][signer]) continue;

            validatorConfirmations[txId][signer] = true;
            tx_.confirmations++;
            emit BridgeConfirmed(txId, signer, tx_.confirmations);
        }

        if (tx_.confirmations >= MIN_CONFIRMATIONS) {
            IERC20 nox = IERC20(NOX_TOKEN);
            uint256 balance = nox.balanceOf(address(this));
            if (balance < amount) revert InsufficientLiquidity();

            tx_.status = BridgeStatus.COMPLETED;
            _removePending(txId);

            if (!nox.transfer(ethRecipient, amount)) revert TransferFailed();

            totalBridgedToEth += amount;
            emit BridgeToEth(txId, cfSender, ethRecipient, amount);
            emit BridgeCompleted(txId, cfTxHash);
        }
    }

    function refundFailedBridge(bytes32 txId, string calldata reason) external onlyRole(ADMIN_ROLE) {
        BridgeTransaction storage tx_ = transactions[txId];
        if (tx_.txId == bytes32(0)) revert TransactionNotFound();
        if (tx_.status == BridgeStatus.COMPLETED || tx_.status == BridgeStatus.REFUNDED) revert InvalidStatus();
        if (tx_.direction != BridgeDirection.ETH_TO_CF) revert InvalidStatus();

        tx_.status = BridgeStatus.REFUNDED;
        _removePending(txId);

        IERC20 nox = IERC20(NOX_TOKEN);
        uint256 refundAmount = tx_.netAmount;

        if (!nox.transfer(tx_.ethAddress, refundAmount)) revert TransferFailed();

        totalBridgedToCell -= refundAmount;

        emit BridgeFailed(txId, reason);
        emit BridgeRefunded(txId, tx_.ethAddress, refundAmount);
    }

    function addLiquidity(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20 nox = IERC20(NOX_TOKEN);
        if (!nox.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        emit LiquidityAdded(msg.sender, amount);
    }

    function removeLiquidity(uint256 amount) external onlyRole(ADMIN_ROLE) {
        IERC20 nox = IERC20(NOX_TOKEN);
        uint256 balance = nox.balanceOf(address(this));

        uint256 pendingOutbound = 0;
        for (uint256 i = 0; i < pendingTransactions.length; i++) {
            BridgeTransaction storage tx_ = transactions[pendingTransactions[i]];
            if (tx_.direction == BridgeDirection.CF_TO_ETH && tx_.status != BridgeStatus.COMPLETED) {
                pendingOutbound += tx_.amount;
            }
        }

        uint256 available = balance > pendingOutbound ? balance - pendingOutbound : 0;
        require(amount <= available, "Exceeds available");

        if (!nox.transfer(msg.sender, amount)) revert TransferFailed();

        emit LiquidityRemoved(msg.sender, amount);
    }

    function _recoverSigner(
        bytes32 txId,
        bytes32 cfTxHash,
        address recipient,
        uint256 amount,
        bytes memory signature
    ) internal pure returns (address) {
        bytes32 messageHash = keccak256(abi.encodePacked(txId, cfTxHash, recipient, amount));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
        return ecrecover(ethSignedHash, v, r, s);
    }

    function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid sig length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
    }

    function _checkDailyLimit(uint256 amount) internal view {
        uint256 today = block.timestamp / 1 days;
        DailyLimit storage limit = dailyLimits[today];
        if (limit.totalBridged + amount > dailyLimit) revert DailyLimitExceeded();
    }

    function _updateDailyLimit(uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        DailyLimit storage limit = dailyLimits[today];
        if (limit.date != today) {
            limit.date = today;
            limit.totalBridged = 0;
        }
        limit.totalBridged += amount;
    }

    function _removePending(bytes32 txId) internal {
        uint256 index = _pendingIndex[txId];
        uint256 lastIndex = pendingTransactions.length - 1;

        if (index != lastIndex) {
            bytes32 lastTxId = pendingTransactions[lastIndex];
            pendingTransactions[index] = lastTxId;
            _pendingIndex[lastTxId] = index;
        }

        pendingTransactions.pop();
        delete _pendingIndex[txId];
    }

    function getTransaction(bytes32 txId) external view returns (BridgeTransaction memory) {
        return transactions[txId];
    }

    function getUserTransactions(address user) external view returns (bytes32[] memory) {
        return userTransactions[user];
    }

    function getPendingTransactions() external view returns (bytes32[] memory) {
        return pendingTransactions;
    }

    function getLiquidity() external view returns (uint256) {
        return IERC20(NOX_TOKEN).balanceOf(address(this));
    }

    function getDailyUsage() external view returns (uint256 used, uint256 limit_) {
        uint256 today = block.timestamp / 1 days;
        return (dailyLimits[today].totalBridged, dailyLimit);
    }

    function getStats() external view returns (
        uint256 bridgedToCell,
        uint256 bridgedToEth,
        uint256 fees,
        uint256 pending,
        uint256 liquidity
    ) {
        return (
            totalBridgedToCell,
            totalBridgedToEth,
            totalFeesCollected,
            pendingTransactions.length,
            IERC20(NOX_TOKEN).balanceOf(address(this))
        );
    }

    function setDailyLimit(uint256 _limit) external onlyRole(ADMIN_ROLE) {
        uint256 oldLimit = dailyLimit;
        dailyLimit = _limit;
        emit DailyLimitUpdated(oldLimit, _limit);
    }

    function setFeeCollector(address _feeCollector) external onlyRole(ADMIN_ROLE) {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
    }

    function addValidator(address validator) external onlyRole(ADMIN_ROLE) {
        _grantRole(VALIDATOR_ROLE, validator);
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyRole(ADMIN_ROLE) {
        _revokeRole(VALIDATOR_ROLE, validator);
        emit ValidatorRemoved(validator);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
