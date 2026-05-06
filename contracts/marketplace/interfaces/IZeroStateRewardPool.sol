// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IZeroStateRewardPool {
    function notifyRewardETH() external payable;
    function notifyRewardERC20(address token, uint256 amount) external;
}

interface IStakingRewards {
    function notifyRewardETH() external payable;
    function notifyRewardERC20(address token, uint256 amount) external;
}
