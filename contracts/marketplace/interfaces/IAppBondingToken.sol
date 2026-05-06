// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IAppBondingToken {
    struct AppLink {
        bytes32 capsuleId;
        bytes32 releaseId;
        bytes32 manifestHash;
        bytes32 packageHash;
        address publisher;
    }

    event Buy(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 feePaid, uint256 newSupply);
    event Sell(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 feePaid, uint256 newSupply);
    event Graduated(uint256 supplyAtGraduation, uint256 reserveAtGraduation, uint256 timestamp);
    event TradingPaused(address indexed by, uint256 timestamp);
    event TradingResumed(address indexed by, uint256 timestamp);
    event EmergencyState(address indexed by, string reason);

    function initialize(
        AppLink calldata link,
        address feeRouter,
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        uint256 graduationSupply_,
        uint16  feeBps_
    ) external;

    function buy(uint256 minTokensOut) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minEthOut) external returns (uint256 ethOut);
    function graduate() external;

    function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut, uint256 fee);
    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut, uint256 fee);
    function currentPrice() external view returns (uint256);
    function reserveBalance() external view returns (uint256);
    function bondingSupply() external view returns (uint256);
    function graduationProgress() external view returns (uint256 progressBps);
    function isGraduated() external view returns (bool);
    function appLink() external view returns (AppLink memory);
}
