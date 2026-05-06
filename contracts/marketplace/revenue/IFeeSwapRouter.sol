// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IAppTokenFactoryLite {
    function isAppToken(address token) external view returns (bool);
}

struct SwapParams {
    address inputToken;
    uint256 amountIn;
    address target;
    bytes   data;
    address outputToken;
    uint256 minOut;
    address receiver;
    bytes32 routeId;
}

interface IFeeSwapRouter {
    function swap(SwapParams calldata p) external payable;
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function paused() external view returns (bool);
    function isApprovedTarget(address target) external view returns (bool);
    function MAX_FEE_BPS() external pure returns (uint16);
}
