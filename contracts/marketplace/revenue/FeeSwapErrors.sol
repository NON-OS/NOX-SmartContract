// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract FeeSwapErrors {
    error FeeExceedsCap();
    error ZeroFeeRecipient();
    error ZeroAddress();
    error TargetNotApproved(address target);
    error SwapFailed(bytes data);
    error InsufficientOutput(uint256 got, uint256 minOut);
    error PausedError();
    error NotPayable();
    error ZeroAmount();
}
