// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./ICellframeBridge.sol";
import "./interfaces/IERC20.sol";

contract CellframeBridge is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ICellframeBridge
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    uint256 public constant MIN_SIGNATURES = 3;
    uint256 public constant BRIDGE_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10000;

    address public feeCollector;
    uint256 public requiredSignatures;
    uint256 private _requestCount;

    mapping(bytes32 => BridgeRequest) private _requests;
    mapping(bytes32 => mapping(address => bool)) private _signatures;
    mapping(bytes32 => uint256) private _signatureCount;
    bytes32[] private _pendingRequestIds;
    mapping(bytes32 => uint256) private _pendingIndex;

    mapping(address => bytes32) public ethToCfToken;
    mapping(bytes32 => address) public cfToEthToken;

    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSignature();
    error AlreadySigned();
    error RequestNotFound();
    error RequestAlreadyCompleted();
    error InsufficientSignatures();
    error TokenNotRegistered();
    error TransferFailed();
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

    function initialize(address _feeCollector, address _admin) public initializer {
        if (_feeCollector == address(0) || _admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        feeCollector = _feeCollector;
        requiredSignatures = MIN_SIGNATURES;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(VALIDATOR_ROLE, _admin);

        _reentrancyStatus = _NOT_ENTERED;
    }

    function registerTokenPair(address ethToken, bytes32 cfToken) external onlyRole(ADMIN_ROLE) {
        if (ethToken == address(0)) revert ZeroAddress();
        ethToCfToken[ethToken] = cfToken;
        cfToEthToken[cfToken] = ethToken;
    }

    function initiateBridgeToCellframe(
        address ethToken,
        bytes32 cfToken,
        uint256 amount,
        bytes32 cfRecipient
    ) external nonReentrant whenNotPaused returns (bytes32 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (ethToCfToken[ethToken] == bytes32(0) && cfToken == bytes32(0)) revert TokenNotRegistered();

        bytes32 actualCfToken = cfToken != bytes32(0) ? cfToken : ethToCfToken[ethToken];

        uint256 fee = (amount * BRIDGE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 bridgeAmount = amount - fee;

        if (!IERC20(ethToken).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (fee > 0) {
            if (!IERC20(ethToken).transfer(feeCollector, fee)) revert TransferFailed();
        }

        requestId = keccak256(abi.encodePacked(
            msg.sender,
            cfRecipient,
            ethToken,
            actualCfToken,
            bridgeAmount,
            block.timestamp,
            _requestCount++
        ));

        _requests[requestId] = BridgeRequest({
            requestId: requestId,
            sender: msg.sender,
            cfRecipient: cfRecipient,
            ethToken: ethToken,
            cfToken: actualCfToken,
            amount: bridgeAmount,
            timestamp: block.timestamp,
            completed: false,
            isOutbound: true
        });

        _pendingRequestIds.push(requestId);
        _pendingIndex[requestId] = _pendingRequestIds.length - 1;

        emit BridgeInitiated(requestId, msg.sender, cfRecipient, bridgeAmount, true);
    }

    function completeBridgeFromCellframe(
        bytes32 requestId,
        address ethToken,
        address recipient,
        uint256 amount,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        BridgeRequest storage request = _requests[requestId];

        if (request.requestId == bytes32(0)) {
            request.requestId = requestId;
            request.ethToken = ethToken;
            request.amount = amount;
            request.timestamp = block.timestamp;
            request.isOutbound = false;
        }

        if (request.completed) revert RequestAlreadyCompleted();

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(requestId, ethToken, recipient, amount, signatures[i]);

            if (!hasRole(VALIDATOR_ROLE, signer)) revert InvalidSignature();
            if (_signatures[requestId][signer]) revert AlreadySigned();

            _signatures[requestId][signer] = true;
            _signatureCount[requestId]++;
        }

        if (_signatureCount[requestId] < requiredSignatures) revert InsufficientSignatures();

        request.completed = true;
        _removePendingRequest(requestId);

        if (!IERC20(ethToken).transfer(recipient, amount)) revert TransferFailed();

        emit BridgeCompleted(requestId, requestId);
    }

    function _recoverSigner(
        bytes32 requestId,
        address ethToken,
        address recipient,
        uint256 amount,
        bytes memory signature
    ) internal pure returns (address) {
        bytes32 messageHash = keccak256(abi.encodePacked(requestId, ethToken, recipient, amount));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
        return ecrecover(ethSignedHash, v, r, s);
    }

    function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid signature length");

        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        if (v < 27) {
            v += 27;
        }
    }

    function _removePendingRequest(bytes32 requestId) internal {
        uint256 index = _pendingIndex[requestId];
        uint256 lastIndex = _pendingRequestIds.length - 1;

        if (index != lastIndex) {
            bytes32 lastRequestId = _pendingRequestIds[lastIndex];
            _pendingRequestIds[index] = lastRequestId;
            _pendingIndex[lastRequestId] = index;
        }

        _pendingRequestIds.pop();
        delete _pendingIndex[requestId];
    }

    function markRequestCompleted(bytes32 requestId, bytes32 txHash) external onlyRole(VALIDATOR_ROLE) {
        BridgeRequest storage request = _requests[requestId];
        if (request.requestId == bytes32(0)) revert RequestNotFound();
        if (request.completed) revert RequestAlreadyCompleted();

        request.completed = true;
        _removePendingRequest(requestId);

        emit BridgeCompleted(requestId, txHash);
    }

    function markRequestFailed(bytes32 requestId, string calldata reason) external onlyRole(VALIDATOR_ROLE) {
        BridgeRequest storage request = _requests[requestId];
        if (request.requestId == bytes32(0)) revert RequestNotFound();

        if (request.isOutbound && !request.completed) {
            if (!IERC20(request.ethToken).transfer(request.sender, request.amount)) revert TransferFailed();
        }

        request.completed = true;
        _removePendingRequest(requestId);

        emit BridgeFailed(requestId, reason);
    }

    function getBridgeRequest(bytes32 requestId) external view returns (BridgeRequest memory) {
        return _requests[requestId];
    }

    function getPendingRequests() external view returns (bytes32[] memory) {
        return _pendingRequestIds;
    }

    function isValidator(address account) external view returns (bool) {
        return hasRole(VALIDATOR_ROLE, account);
    }

    function getSignatureCount(bytes32 requestId) external view returns (uint256) {
        return _signatureCount[requestId];
    }

    function hasSigned(bytes32 requestId, address validator) external view returns (bool) {
        return _signatures[requestId][validator];
    }

    function setRequiredSignatures(uint256 _required) external onlyRole(ADMIN_ROLE) {
        require(_required >= MIN_SIGNATURES, "Below minimum");
        requiredSignatures = _required;
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

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
