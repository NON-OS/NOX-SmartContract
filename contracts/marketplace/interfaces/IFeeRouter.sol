// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IFeeRouter {
    enum RevenueSource {
        AppPurchase,
        Subscription,
        PayPerUse,
        TokenLaunch,
        TradingFee,
        GraduationFee,
        ValidationFee
    }

    struct SplitProfile {
        uint16 publisherBps;
        uint16 nftHoldersBps;
        uint16 stakersBps;
        uint16 treasuryBps;
        bool   configured;
    }

    event SplitProfileUpdated(RevenueSource indexed source, SplitProfile profile);
    event RevenueRouted(
        RevenueSource indexed source,
        bytes32 indexed capsuleId,
        address indexed publisher,
        address asset,
        uint256 total,
        uint256 publisherAmt,
        uint256 nftHoldersAmt,
        uint256 stakersAmt,
        uint256 treasuryAmt
    );
    event SinkUpdated(string indexed kind, address oldSink, address newSink);

    function routeERC20(
        RevenueSource source,
        bytes32 capsuleId,
        address publisher,
        address token,
        uint256 amount
    ) external;

    function routeETH(
        RevenueSource source,
        bytes32 capsuleId,
        address publisher
    ) external payable;

    function getSplitProfile(RevenueSource source) external view returns (SplitProfile memory);
    function setSplitProfile(RevenueSource source, SplitProfile calldata profile) external;
    function capsuleRevenue(bytes32 capsuleId, address asset) external view returns (uint256);
    function publisherRevenue(address publisher, address asset) external view returns (uint256);
}
