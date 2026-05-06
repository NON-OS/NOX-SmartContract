// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract FeeSwapEvents {
    event ProtocolFeeCollected(address indexed asset, address indexed payer, address indexed recipient, uint256 amount);
    event SwapExecuted(
        bytes32 indexed route,
        address indexed payer,
        address indexed receiver,
        address inputAsset,
        address outputAsset,
        uint256 amountIn,
        uint256 amountInAfterFee,
        uint256 amountOut
    );
    event LeftoverRefunded(address indexed asset, address indexed to, uint256 amount);
    event TargetApprovalSet(address indexed target, bool approved);
    event AppTokenFactorySet(address indexed oldFactory, address indexed newFactory);
    event FeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PausedSet(bool paused);
    event Rescued(address indexed asset, address indexed to, uint256 amount);
}
