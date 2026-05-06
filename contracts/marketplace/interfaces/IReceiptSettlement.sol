// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IReceiptSettlement {
    struct Receipt {
        bytes32 capsuleId;
        address user;
        address publisher;
        uint256 amountNox;
        uint256 nonce;
        uint256 epoch;
        uint256 expiry;
        bytes32 receiptType;
        bytes   signature;
    }

    event ReceiptSettled(
        bytes32 indexed receiptHash,
        bytes32 indexed capsuleId,
        address indexed user,
        address publisher,
        uint256 amountNox,
        bytes32 receiptType
    );
    event ReceiptRejected(bytes32 indexed receiptHash, bytes32 indexed capsuleId, string reason);
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event NoxTokenUpdated(address oldToken, address newToken);

    function batchSettle(Receipt[] calldata receipts)
        external
        returns (uint256 settled, uint256 rejected);

    function isUsed(bytes32 receiptHash) external view returns (bool);
    function currentEpoch() external view returns (uint256);
    function hashReceipt(Receipt calldata r) external view returns (bytes32);
    function recoverSigner(Receipt calldata r) external view returns (address);
}
