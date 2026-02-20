// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeRouter {
    event FeeCollected(address indexed service, uint256 amount, uint256 indexed epoch);
    event FeesFlushed(uint256 indexed epoch, uint256 amount);
    event ServiceAuthorized(address indexed service);
    event ServiceDeauthorized(address indexed service);
    event PLPUpdated(address indexed newPLP);

    function noxToken() external view returns (address);
    function privacyLiquidityPool() external view returns (address);
    function startTimestamp() external view returns (uint256);
    function pendingFees() external view returns (uint256);
    function lastFlushEpoch() external view returns (uint256);
    function authorizedServices(address service) external view returns (bool);
    function serviceFeesCollected(address service) external view returns (uint256);

    function collectFee(uint256 amount) external;
    function flushToPLP() external;

    function addAuthorizedService(address service) external;
    function removeAuthorizedService(address service) external;

    function isAuthorizedService(address service) external view returns (bool);
    function getCurrentEpoch() external view returns (uint256);
    function getTotalFeesCollected() external view returns (uint256);
}
