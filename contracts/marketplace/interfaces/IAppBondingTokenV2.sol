// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IAppBondingTokenV2 {
    struct AppLink {
        bytes32 capsuleId;
        bytes32 releaseId;
        bytes32 manifestHash;
        bytes32 packageHash;
        address publisher;
    }

    struct GraduationConfig {
        uint256 graduationSupply;
        uint256 lpReserveCap;
        uint16  tradingFeeBps;
        uint16  graduationFeeBps;
        address weth;
        address uniV2Factory;
        address uniV2Router;
        address lpBurnTo;
    }

    event Buy(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 feePaid, uint256 newSupply);
    event Sell(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 feePaid, uint256 newSupply);
    event Graduated(uint256 supplyAtGraduation, uint256 reserveAtGraduation, uint256 timestamp);
    event TradingPaused(address indexed by, uint256 timestamp);
    event TradingResumed(address indexed by, uint256 timestamp);
    event EmergencyState(address indexed by, string reason);

    event GraduatedToUniswap(
        address indexed pair,
        address indexed lpBurnTo,
        uint256 ethToLp,
        uint256 tokensToLp,
        uint256 liquidityMinted,
        uint256 graduationFeePaid,
        uint256 terminalPriceWeiPerToken
    );
    event UniswapPairCreated(address indexed pair, address indexed token0, address indexed token1);

    error LpReserveCapTooLow(uint256 maxRequired, uint256 declaredCap);
    error LpReserveCapZero();
    error GraduationFeeTooHigh(uint16 cap, uint16 supplied);
    error PairAlreadySeeded(uint112 reserve0, uint112 reserve1);
    error LiquidityCreationFailed(uint256 expectedToken, uint256 expectedEth, uint256 actualToken, uint256 actualEth);
    error PostGraduationStuckTokens(uint256 stuckBalance);
    error PostGraduationStuckEth(uint256 stuckEth);
    error InvalidUniswapAddresses();
    error AlreadyConfigured();

    function initialize(
        AppLink calldata link,
        address feeRouter_,
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        GraduationConfig calldata cfg
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

    function pair() external view returns (address);
    function lpBurnTo() external view returns (address);
    function lpReserveCap() external view returns (uint256);
    function graduationFeeBps() external view returns (uint16);
    function terminalPriceWeiPerToken() external view returns (uint256);
    function maxTokensToLp() external view returns (uint256);
    function expectedTokensToLp() external view returns (uint256);
}
