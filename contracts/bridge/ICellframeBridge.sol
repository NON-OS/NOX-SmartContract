// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICellframeBridge {
    struct BridgeRequest {
        bytes32 requestId;
        address sender;
        bytes32 cfRecipient;
        address ethToken;
        bytes32 cfToken;
        uint256 amount;
        uint256 timestamp;
        bool completed;
        bool isOutbound;
    }

    event BridgeInitiated(
        bytes32 indexed requestId,
        address indexed sender,
        bytes32 cfRecipient,
        uint256 amount,
        bool isOutbound
    );
    event BridgeCompleted(bytes32 indexed requestId, bytes32 txHash);
    event BridgeFailed(bytes32 indexed requestId, string reason);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);

    function initiateBridgeToCellframe(
        address ethToken,
        bytes32 cfToken,
        uint256 amount,
        bytes32 cfRecipient
    ) external returns (bytes32 requestId);

    function completeBridgeFromCellframe(
        bytes32 requestId,
        address ethToken,
        address recipient,
        uint256 amount,
        bytes[] calldata signatures
    ) external;

    function getBridgeRequest(bytes32 requestId) external view returns (BridgeRequest memory);
    function getPendingRequests() external view returns (bytes32[] memory);
    function isValidator(address account) external view returns (bool);
    function requiredSignatures() external view returns (uint256);
}
